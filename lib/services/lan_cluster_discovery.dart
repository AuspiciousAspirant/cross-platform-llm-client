import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:llama_flutter_android/llama_flutter_android.dart';

/// Zero-configuration LAN worker discovery service for PrivateLM.
///
/// Uses UDP broadcast on port 50053 to announce active workers and discover
/// nearby worker nodes (PC, Mac, Linux, Android) across the local network.
class LanClusterDiscovery {
  static const int discoveryPort = 50053;
  static const String packetType = 'privatelm_worker';
  static const Duration broadcastInterval = Duration(seconds: 3);

  RawDatagramSocket? _broadcastSocket;
  Timer? _broadcastTimer;
  ClusterWorker? _broadcastingWorker;

  RawDatagramSocket? _listenSocket;
  StreamSubscription<RawSocketEvent>? _listenSubscription;
  void Function(ClusterWorker)? _onWorkerDiscovered;

  final Set<String> _selfIps = {};
  String? _selfWorkerId;

  bool get isBroadcasting => _broadcastTimer != null;
  bool get isListening => _listenSocket != null;

  /// Builds a standard beacon JSON payload from worker metadata.
  static Map<String, dynamic> buildBeaconData(ClusterWorker worker) {
    return {
      'type': packetType,
      'id': worker.id,
      'name': worker.name,
      'host': worker.host,
      'port': worker.port,
      'ramMb': worker.ramMb,
      'bandwidth': worker.bandwidth,
      'model': worker.model,
    };
  }

  /// Encodes a worker beacon into a UTF-8 JSON byte payload.
  static Uint8List encodeBeacon(ClusterWorker worker) {
    final map = buildBeaconData(worker);
    return Uint8List.fromList(utf8.encode(jsonEncode(map)));
  }

  /// Parses a beacon JSON map or string into a [ClusterWorker].
  ///
  /// Returns `null` if the packet is invalid or not a `privatelm_worker` beacon.
  static ClusterWorker? parseBeacon(dynamic rawData, {String? senderAddress}) {
    try {
      Map<dynamic, dynamic> map;
      if (rawData is String) {
        final decoded = jsonDecode(rawData);
        if (decoded is! Map) return null;
        map = decoded;
      } else if (rawData is Map) {
        map = rawData;
      } else {
        return null;
      }

      if (map['type'] != packetType) return null;

      final rawHost = map['host'] as String?;
      final host = (rawHost != null && rawHost.isNotEmpty && rawHost != '0.0.0.0')
          ? rawHost
          : (senderAddress ?? '');
      if (host.isEmpty) return null;

      final rawPort = map['port'];
      final port = (rawPort is num)
          ? rawPort.toInt()
          : (int.tryParse('$rawPort') ?? LlamaCluster.defaultPort);

      final rawName = map['name'] as String?;
      final name = (rawName != null && rawName.isNotEmpty) ? rawName : host;

      final ramMb = (map['ramMb'] as num?)?.toInt();
      final bandwidth = (map['bandwidth'] as num?)?.toDouble();
      final model = map['model'] as String?;
      final id = map['id'] as String?;

      return ClusterWorker(
        name: name,
        host: host,
        port: port,
        ramMb: ramMb,
        bandwidth: bandwidth,
        model: model,
        id: id,
      );
    } catch (_) {
      return null;
    }
  }

  /// Parses raw UDP datagram bytes into a [ClusterWorker].
  static ClusterWorker? parseDatagramBytes(List<int> bytes, {String? senderAddress}) {
    try {
      final text = utf8.decode(bytes);
      return parseBeacon(text, senderAddress: senderAddress);
    } catch (_) {
      return null;
    }
  }

  /// Starts broadcasting worker presence on the local network.
  ///
  /// Periodically sends UDP broadcast packets containing [worker] metadata
  /// to `255.255.255.255` and local subnet broadcast on port 50053.
  Future<void> startBroadcasting({required ClusterWorker worker}) async {
    if (kIsWeb) return;
    _broadcastingWorker = worker;
    if (worker.id != null) {
      _selfWorkerId = worker.id;
    }
    if (worker.host.isNotEmpty) {
      _selfIps.add(worker.host);
    }

    await _initBroadcastSocket();

    _broadcastTimer?.cancel();
    _sendBeacon();
    _broadcastTimer = Timer.periodic(broadcastInterval, (_) {
      _sendBeacon();
    });
  }

  Future<void> _initBroadcastSocket() async {
    if (_broadcastSocket != null) return;
    try {
      final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      _broadcastSocket = socket;
    } catch (e) {
      debugPrint('[LanClusterDiscovery] Failed to bind broadcast socket: $e');
    }
  }

  void _sendBeacon() {
    final worker = _broadcastingWorker;
    final socket = _broadcastSocket;
    if (worker == null || socket == null) return;

    try {
      final bytes = encodeBeacon(worker);

      // Primary global LAN broadcast address
      try {
        socket.send(bytes, InternetAddress('255.255.255.255'), discoveryPort);
      } catch (e) {
        debugPrint('[LanClusterDiscovery] Broadcast 255.255.255.255 failed: $e');
      }

      // Subnet broadcast fallback (e.g. 192.168.1.255) for routers with restrictive filters
      final parts = worker.host.split('.');
      if (parts.length == 4) {
        final subnetBroadcast = '${parts[0]}.${parts[1]}.${parts[2]}.255';
        try {
          socket.send(bytes, InternetAddress(subnetBroadcast), discoveryPort);
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('[LanClusterDiscovery] Beacon send error: $e');
    }
  }

  /// Stops broadcasting the worker beacon and closes the broadcast socket.
  void stopBroadcasting() {
    _broadcastTimer?.cancel();
    _broadcastTimer = null;
    _broadcastingWorker = null;
    try {
      _broadcastSocket?.close();
    } catch (_) {}
    _broadcastSocket = null;
  }

  /// Starts listening for worker UDP broadcast announcements on port 50053.
  ///
  /// Incoming packets from other devices invoke [onWorkerDiscovered].
  /// Own announcements are automatically filtered out.
  Future<void> startListening({
    required void Function(ClusterWorker) onWorkerDiscovered,
    String? selfWorkerId,
  }) async {
    if (kIsWeb) return;
    _onWorkerDiscovered = onWorkerDiscovered;
    if (selfWorkerId != null && selfWorkerId.isNotEmpty) {
      _selfWorkerId = selfWorkerId;
    }

    if (_listenSocket != null) return;

    await _collectLocalIps();

    try {
      RawDatagramSocket? socket;
      try {
        socket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          discoveryPort,
          reuseAddress: true,
          reusePort: true,
        );
      } catch (_) {
        // Fallback for platforms where reusePort is not supported (e.g. Windows)
        socket = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4,
          discoveryPort,
          reuseAddress: true,
          reusePort: false,
        );
      }

      _listenSocket = socket;
      _listenSubscription = socket.listen(
        (RawSocketEvent event) {
          if (event == RawSocketEvent.read) {
            final datagram = socket?.receive();
            if (datagram != null) {
              _handleIncomingDatagram(datagram);
            }
          }
        },
        onError: (err) {
          debugPrint('[LanClusterDiscovery] Listener stream error: $err');
        },
        cancelOnError: false,
      );
    } catch (e) {
      debugPrint('[LanClusterDiscovery] Could not bind listen socket on port $discoveryPort: $e');
    }
  }

  Future<void> _collectLocalIps() async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          _selfIps.add(addr.address);
        }
      }
    } catch (_) {}
  }

  void _handleIncomingDatagram(Datagram datagram) {
    try {
      final senderIp = datagram.address.address;
      final text = utf8.decode(datagram.data);
      final decoded = jsonDecode(text);
      if (decoded is! Map) return;

      final map = Map<String, dynamic>.from(decoded);
      if (map['type'] != packetType) return;

      final packetId = map['id']?.toString();
      final packetHost = map['host']?.toString();

      // Filter out this device's own announcements
      if (_selfWorkerId != null && packetId != null && packetId == _selfWorkerId) {
        return;
      }
      if (_broadcastingWorker != null) {
        if (_broadcastingWorker!.id != null && packetId == _broadcastingWorker!.id) {
          return;
        }
        if (packetHost == _broadcastingWorker!.host) {
          return;
        }
      }
      if (packetHost != null && _selfIps.contains(packetHost)) {
        return;
      }
      if (_selfIps.contains(senderIp) && (_selfWorkerId != null || _broadcastingWorker != null)) {
        return;
      }

      final worker = parseBeacon(map, senderAddress: senderIp);
      if (worker != null) {
        _onWorkerDiscovered?.call(worker);
      }
    } catch (e) {
      // Ignore corrupted or malformed datagrams cleanly
    }
  }

  /// Stops listening for worker broadcasts and releases port 50053.
  void stopListening() {
    _onWorkerDiscovered = null;
    try {
      _listenSubscription?.cancel();
    } catch (_) {}
    _listenSubscription = null;
    try {
      _listenSocket?.close();
    } catch (_) {}
    _listenSocket = null;
  }

  /// Completely disposes discovery resources.
  void dispose() {
    stopBroadcasting();
    stopListening();
  }
}
