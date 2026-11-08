import 'dart:async';
import 'dart:io' show File, InternetAddress, InternetAddressType, NetworkInterface, Platform, ServerSocket, Socket;
import 'dart:math' as math;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';

import '../core/constants.dart';
import '../core/ui.dart';
import '../controllers/model_controller.dart';
import 'app_log_service.dart';
import 'cluster_benchmark_service.dart';
import 'desktop_inference_engine.dart';
import 'desktop_rpc_worker.dart';
import 'hive_service.dart';
import 'inference_service.dart';
import 'lan_cluster_discovery.dart';

/// Diagnostics result for LAN network, ports, binaries, and memory.
class ClusterDiagnosticsReport {
  final bool hasLanIp;
  final String? lanIp;
  final bool isPort50052Available;
  final bool isWorkerRunning;
  final bool hasWorkerBinary;
  final String? workerBinaryPath;
  final bool hasMasterBinary;
  final String? masterBinaryPath;
  final double memoryBandwidthGbps;
  final int freeRamMb;
  final List<String> networkAdapters;
  final String statusSummary;
  final bool isReady;

  const ClusterDiagnosticsReport({
    required this.hasLanIp,
    this.lanIp,
    required this.isPort50052Available,
    required this.isWorkerRunning,
    required this.hasWorkerBinary,
    this.workerBinaryPath,
    required this.hasMasterBinary,
    this.masterBinaryPath,
    required this.memoryBandwidthGbps,
    required this.freeRamMb,
    required this.networkAdapters,
    required this.statusSummary,
    required this.isReady,
  });
}

/// What this phone does in a phone cluster.
enum ClusterRole {
  off,

  /// Runs the model, with part of it on the workers.
  master,

  /// Lends its processor and memory to a master.
  worker,
}

/// One phone's or computer's part of the loaded model.
class ClusterShare {
  final String name;
  final double mb;
  final bool isThisPhone;
  final int startLayer;
  final int endLayer;
  final String endpoint;
  final int? pingMs;
  final bool isHealthy;

  const ClusterShare(
    this.name,
    this.mb, {
    this.isThisPhone = false,
    this.startLayer = 0,
    this.endLayer = 0,
    this.endpoint = '',
    this.pingMs,
    this.isHealthy = true,
  });

  ClusterShare copyWith({
    String? name,
    double? mb,
    bool? isThisPhone,
    int? startLayer,
    int? endLayer,
    String? endpoint,
    int? pingMs,
    bool? isHealthy,
  }) =>
      ClusterShare(
        name ?? this.name,
        mb ?? this.mb,
        isThisPhone: isThisPhone ?? this.isThisPhone,
        startLayer: startLayer ?? this.startLayer,
        endLayer: endLayer ?? this.endLayer,
        endpoint: endpoint ?? this.endpoint,
        pingMs: pingMs ?? this.pingMs,
        isHealthy: isHealthy ?? this.isHealthy,
      );
}

/// A phone the master can put layers on, for planning a load.
class _Phone {
  final ClusterWorker? worker; // null: the master itself
  final double capacityMb;
  final double speed; // GB/s
  double assignedMb = 0;
  _Phone(this.worker, this.capacityMb, this.speed);
}

/// Phone cluster: spread a GGUF model across phones on the same Wi-Fi.
/// The master runs the model; workers hold part of its layers.
class ClusterService extends GetxService {
  final HiveService _hive = Get.find<HiveService>();

  final DesktopRpcWorker _desktopWorker = DesktopRpcWorker();
  DesktopRpcWorker get desktopWorker => _desktopWorker;

  final LanClusterDiscovery _lanDiscovery = LanClusterDiscovery();
  LanClusterDiscovery get lanDiscovery => _lanDiscovery;

  /// Distributed inference benchmark service for evaluating throughput and speedup.
  ClusterBenchmarkService get benchmark => Get.isRegistered<ClusterBenchmarkService>()
      ? Get.find<ClusterBenchmarkService>()
      : Get.put(ClusterBenchmarkService(), permanent: true);

  /// Latest paired comparison between local and cluster inference benchmarks.
  Rx<BenchmarkComparison?> get latestBenchmarkComparison => benchmark.latestComparison;

  /// Runs the standardized 64-token synthetic inference benchmark.
  Future<BenchmarkResult?> runBenchmark({
    bool? isCluster,
    int targetTokens = ClusterBenchmarkService.standardizedTargetTokens,
  }) async {
    return benchmark.runBenchmark(
      isCluster: isCluster ?? (enabled.value && workers.isNotEmpty),
      targetTokens: targetTokens,
    );
  }

  static bool get isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  static bool get isSupported => !kIsWeb;

  /// Running a model across workers: Android and Desktop PC (Windows, Linux, macOS).
  static bool get canBeMaster => !kIsWeb && !Platform.isIOS;

  /// iOS can't stop the worker without closing the app.
  static bool get workerStopsWithApp => !kIsWeb && Platform.isIOS;

  /// QR codes a worker shows: privatelm://worker?host=…&port=…
  static const _qrScheme = 'privatelm';

  /// Speed assumed for workers paired before they reported one (GB/s).
  static const _unknownSpeed = 4.0;

  /// Workers the master can use on its next GGUF load.
  final workers = <ClusterWorker>[].obs;

  /// Master mode: use [workers] when loading GGUF models.
  final enabled = false.obs;

  final found = <ClusterWorker>[].obs;
  final isScanning = false.obs;

  /// This phone's worker service.
  final worker = const ClusterWorkerStatus(state: 'stopped').obs;
  final _workerRequested = false.obs;

  /// The API server is running (other devices, e.g. a PC, use the model).
  final serving = false.obs;

  /// This phone's Wi-Fi address, or null when it isn't on Wi-Fi.
  final wifiAddress = RxnString();

  /// How the loaded model is spread across phones; empty when it isn't.
  final split = <ClusterShare>[].obs;

  /// Average ping of active cluster workers in ms.
  final clusterLatencyMs = 0.obs;

  /// True when all cluster workers respond to health keepalive pings.
  final isClusterHealthy = true.obs;

  /// Live round-trip latency in ms per worker endpoint (null if unreachable).
  final workerPings = <String, int?>{}.obs;

  /// Worker endpoints that have recently failed keepalive pings.
  final droppedWorkers = <String>[].obs;

  Timer? _keepaliveTimer;
  final Map<String, int> _workerFailCounts = {};

  String deviceName = '';
  double? _localSpeed;
  Timer? _statusTimer;

  ClusterRole get role => _workerRequested.value || worker.value.running
      ? ClusterRole.worker
      : enabled.value
          ? ClusterRole.master
          : ClusterRole.off;

  /// "Pixel 8 72% · POCO F1 28%", or null when the model isn't split.
  String? get splitSummary {
    final total = split.fold<double>(0, (a, s) => a + s.mb);
    if (split.length < 2 || total <= 0) return null;
    return split.map((s) => '${s.name} ${(s.mb / total * 100).round()}%').join(' · ');
  }

  @override
  void onInit() {
    super.onInit();
    enabled.value = _hive.getSetting<bool>(AppConstants.keyClusterEnabled) ?? false;
    final saved = _hive.getSetting<List>(AppConstants.keyClusterWorkers) ?? const [];
    workers.assignAll(saved.whereType<Map>().map(ClusterWorker.fromMap));
    if (isSupported) {
      if (!Get.isRegistered<ClusterBenchmarkService>()) {
        Get.put(ClusterBenchmarkService(), permanent: true);
      }
      final infoPlugin = DeviceInfoPlugin();
      if (Platform.isIOS) {
        infoPlugin.iosInfo.then((info) => deviceName = info.modelName);
      } else if (Platform.isAndroid) {
        infoPlugin.androidInfo.then((info) => deviceName = info.model);
      } else if (Platform.isWindows) {
        infoPlugin.windowsInfo.then((info) => deviceName = info.computerName);
      } else if (Platform.isMacOS) {
        infoPlugin.macOsInfo.then((info) => deviceName = info.computerName);
      } else if (Platform.isLinux) {
        infoPlugin.linuxInfo.then((info) => deviceName = info.name);
      }
      refreshWorkerStatus().then((_) {
        if (worker.value.running) {
          _watchWorker();
          if (role == ClusterRole.worker) _startBroadcastingWorker();
        }
      });
      // A worker runs at full speed only while PrivateLM is on screen (it
      // borrows the app's priority), so keep the screen on while sharing.
      ever<ClusterWorkerStatus>(worker, (s) {
        _updateKeepScreenOn();
        if (role == ClusterRole.worker && s.running && wifiAddress.value != null) {
          _startBroadcastingWorker();
        } else if (!s.running && !s.starting) {
          _lanDiscovery.stopBroadcasting();
        }
      });
      ever<bool>(serving, (_) => _updateKeepScreenOn());
      ever<String?>(wifiAddress, (ip) {
        if (role == ClusterRole.worker && worker.value.running && ip != null) {
          _startBroadcastingWorker();
        }
      });
      refreshWifiAddress();
      if (role == ClusterRole.master) {
        _startListeningForWorkers();
      }
    }
  }

  @override
  void onClose() {
    _statusTimer?.cancel();
    _stopMasterKeepalive();
    _lanDiscovery.dispose();
    if (isDesktop) {
      _desktopWorker.stop();
    }
    super.onClose();
  }

  /// Android throttles a phone whose screen is off (slow cores, low CPU
  /// share), so keep it on while this device works for others: as a worker,
  /// or serving the model over the network.
  bool? _screenKeptOn;
  bool get isScreenKeptOn => _screenKeptOn ?? false;

  void _updateKeepScreenOn() {
    if (isDesktop) return;
    final s = worker.value;
    final on = s.running || s.starting || serving.value;
    if (on == _screenKeptOn) return;
    _screenKeptOn = on;
    LlamaCluster.setKeepScreenOn(on).catchError((_) {});
  }

  Future<void> setRole(ClusterRole next) async {
    if (next == role) return;
    if (next != ClusterRole.worker && role == ClusterRole.worker) {
      if (workerStopsWithApp) {
        showToast('Still sharing', 'Close PrivateLM to stop sharing this device.');
        return;
      }
      await stopWorker();
    }
    await _setEnabled(next == ClusterRole.master);
    if (next == ClusterRole.master) {
      _startListeningForWorkers();
    } else {
      _lanDiscovery.stopListening();
    }
    if (next == ClusterRole.worker) await startWorker();
    await refreshWifiAddress();
  }

  // ── Worker ─────────────────────────────────────────────────────────────

  /// What the master scans to add this phone, once the worker is running.
  String? get workerQrData {
    final host = wifiAddress.value;
    final status = worker.value;
    if (host == null || !status.running) return null;
    return Uri(scheme: _qrScheme, host: 'worker', queryParameters: {
      'host': host,
      'port': '${LlamaCluster.defaultPort}',
      if (deviceName.isNotEmpty) 'name': deviceName,
      if (status.ramMb > 0) 'ram': '${status.ramMb}',
      if (status.bandwidth > 0) 'bw': status.bandwidth.toStringAsFixed(1),
      if (status.id != null) 'id': status.id!,
    }).toString();
  }

  Future<void> startWorker() async {
    if (Platform.isAndroid) {
      // Unrestricted battery keeps Android (Samsung especially) from moving
      // the worker to slow cores once it gets busy.
      final status = await LlamaCluster.workerStatus();
      if (!status.batteryUnrestricted) await LlamaCluster.requestBatteryUnrestricted();
    }
    _workerRequested.value = true;
    worker.value = const ClusterWorkerStatus(state: 'starting');
    if (isDesktop) {
      await _desktopWorker.start(port: LlamaCluster.defaultPort);
      await refreshWorkerStatus();
    } else {
      await LlamaCluster.startWorker();
    }
    await refreshWifiAddress();
    _startBroadcastingWorker();
    _watchWorker();
  }

  Future<void> stopWorker() async {
    _workerRequested.value = false;
    _statusTimer?.cancel();
    _lanDiscovery.stopBroadcasting();
    if (isDesktop) {
      await _desktopWorker.stop();
    } else {
      await LlamaCluster.stopWorker();
    }
    await Future.delayed(const Duration(milliseconds: 600));
    await refreshWorkerStatus();
  }

  /// Follows the worker service (its own process) while it runs: whether a
  /// master is connected and how much it holds.
  void _watchWorker() {
    _statusTimer?.cancel();
    var checks = 0;
    _statusTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      await refreshWorkerStatus();
      final s = worker.value;
      if (s.running && !_lanDiscovery.isBroadcasting && wifiAddress.value != null) {
        _startBroadcastingWorker();
      }
      // Give the service a few seconds to come up before calling it stopped.
      if (!s.running && !s.starting && ++checks > 3) {
        _workerRequested.value = false;
        _lanDiscovery.stopBroadcasting();
        _statusTimer?.cancel();
      }
    });
  }

  void _startBroadcastingWorker() {
    if (!isSupported) return;
    final host = wifiAddress.value;
    if (host == null || host.isEmpty) return;
    final s = worker.value;
    final workerObj = ClusterWorker(
      name: deviceName.isNotEmpty ? deviceName : (isDesktop ? 'Desktop Worker' : 'Worker'),
      host: host,
      port: LlamaCluster.defaultPort,
      ramMb: s.ramMb > 0 ? s.ramMb : null,
      bandwidth: s.bandwidth > 0 ? s.bandwidth : null,
      model: deviceName.isNotEmpty ? deviceName : null,
      id: s.id,
    );
    _lanDiscovery.startBroadcasting(worker: workerObj);
  }

  Future<void> refreshWorkerStatus() async {
    try {
      if (isDesktop) {
        worker.value = await _desktopWorker.getStatus();
      } else {
        worker.value = await LlamaCluster.workerStatus();
      }
    } catch (e) {
      Get.find<AppLogService>().error('Cluster worker status failed', details: e);
    }
  }

  /// Finds this device's IPv4 address on Wi-Fi or local Ethernet LAN.
  Future<void> refreshWifiAddress() async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      final preferred = interfaces.where((i) {
        final lower = i.name.toLowerCase();
        // Ignore virtual adapters (WSL, Hyper-V vEthernet, Docker, Tailscale)
        if (lower.contains('vethernet') ||
            lower.contains('virtual') ||
            lower.contains('vmware') ||
            lower.contains('vbox') ||
            lower.contains('docker') ||
            lower.contains('wsl') ||
            lower.contains('tailscale')) {
          return false;
        }
        return lower.contains('wlan') ||
            lower.contains('wi-fi') ||
            lower.contains('wifi') ||
            lower.contains('en0') ||
            lower.contains('eth') ||
            lower.contains('ethernet');
      }).expand((i) => i.addresses).where((a) => !a.isLoopback && !a.address.startsWith('169.254.')).toList();

      final nonLoopback = interfaces
          .expand((i) => i.addresses)
          .where((a) => !a.isLoopback && !a.address.startsWith('169.254.'))
          .toList();

      wifiAddress.value = preferred.isNotEmpty
          ? preferred.first.address
          : (nonLoopback.isNotEmpty ? nonLoopback.first.address : null);
    } catch (_) {
      wifiAddress.value = null;
    }
  }

  // ── Master: workers ────────────────────────────────────────────────────

  /// Adds the worker from a scanned QR code. Returns an error message, or
  /// null on success.
  Future<String?> addFromQr(String data) async {
    final uri = Uri.tryParse(data.trim());
    final params = uri?.queryParameters ?? const {};
    final host = params['host'];
    final port = int.tryParse(params['port'] ?? '');
    if (uri == null || uri.scheme != _qrScheme || host == null || port == null) {
      return 'That isn\'t a PrivateLM worker code';
    }
    return _add(ClusterWorker(
      name: params['name'] ?? host,
      host: host,
      port: port,
      ramMb: int.tryParse(params['ram'] ?? ''),
      bandwidth: double.tryParse(params['bw'] ?? ''),
      model: params['name'],
      id: params['id'],
    ));
  }

  /// Adds a worker by IP ("192.168.1.20" or "192.168.1.20:50052"). Returns
  /// an error message, or null on success.
  Future<String?> addManual(String input) async {
    final text = input.trim();
    if (text.isEmpty) return 'Enter the worker phone\'s IP address';
    final host = text.contains(':') ? text.substring(0, text.lastIndexOf(':')) : text;
    final port = text.contains(':')
        ? int.tryParse(text.substring(text.lastIndexOf(':') + 1))
        : LlamaCluster.defaultPort;
    if (host.isEmpty || port == null) return 'Use the form 192.168.1.20:50052';
    return _add(ClusterWorker(name: host, host: host, port: port));
  }

  Future<String?> addFound(ClusterWorker w) => _add(w);

  /// Finds saved workers that no longer answer at their address (they moved
  /// to another Wi-Fi, a hotspot, or got a new IP) by their device ID on
  /// the network, and updates them. Returns the ones still unreachable.
  Future<List<ClusterWorker>> relocateWorkers() async {
    final missing = <ClusterWorker>[];
    for (final w in workers) {
      if (!await LlamaCluster.probe(w.endpoint)) missing.add(w);
    }
    if (missing.isEmpty) return const [];
    final seen = await LlamaCluster.discover();
    var moved = 0;
    final unreachable = <ClusterWorker>[];
    for (final w in missing) {
      final match = seen.firstWhereOrNull((s) => w.id != null && s.id == w.id);
      final i = workers.indexWhere((x) => x.endpoint == w.endpoint);
      if (match == null || match.endpoint == w.endpoint || i < 0) {
        unreachable.add(w);
        continue;
      }
      workers[i] = w.movedTo(match.host, match.port);
      moved++;
    }
    if (moved > 0) {
      await _save();
      Get.find<AppLogService>().info('Phone cluster: found $moved worker(s) at a new address');
    }
    return unreachable;
  }

  Future<String?> _add(ClusterWorker worker) async {
    if (!await LlamaCluster.probe(worker.endpoint)) {
      return 'Can\'t reach ${worker.endpoint}. Check that the phone is a worker '
          'and on the same Wi-Fi.';
    }
    workers.removeWhere((w) => w.endpoint == worker.endpoint);
    workers.add(worker);
    found.removeWhere((w) => w.endpoint == worker.endpoint);
    await _save();
    return null;
  }

  Future<void> remove(ClusterWorker w) async {
    workers.removeWhere((s) => s.endpoint == w.endpoint);
    await _save();
  }

  bool isAdded(ClusterWorker w) => workers.any((s) => s.endpoint == w.endpoint);

  /// Looks for workers on the Wi-Fi / LAN via UDP discovery and platform mechanisms.
  Future<void> scanNearby() async {
    if (isScanning.value) return;
    isScanning.value = true;
    _startListeningForWorkers();
    try {
      final list = await LlamaCluster.discover();
      for (final w in list) {
        if (!isAdded(w) && !found.any((f) => f.endpoint == w.endpoint)) {
          found.add(w);
        }
      }
    } catch (_) {
    } finally {
      await Future.delayed(const Duration(milliseconds: 1500));
      isScanning.value = false;
    }
  }

  void _startListeningForWorkers() {
    if (!isSupported) return;
    _lanDiscovery.startListening(
      selfWorkerId: worker.value.id,
      onWorkerDiscovered: (discovered) {
        if (isAdded(discovered)) return;
        final existingIdx = found.indexWhere(
          (w) =>
              w.endpoint == discovered.endpoint ||
              (discovered.id != null && w.id != null && w.id == discovered.id),
        );
        if (existingIdx >= 0) {
          found[existingIdx] = discovered;
        } else {
          found.add(discovered);
          Get.find<AppLogService>().info(
            'Auto-discovered LAN worker: ${discovered.model ?? discovered.name} (${discovered.endpoint})',
          );
        }
      },
    );
  }

  Future<void> _setEnabled(bool value) async {
    enabled.value = value;
    await _hive.setSetting(AppConstants.keyClusterEnabled, value);
  }

  Future<void> _save() => _hive.setSetting(
      AppConstants.keyClusterWorkers, [for (final w in workers) w.toMap()]);

  // ── Master: loading ────────────────────────────────────────────────────

  /// Plans a GGUF load right before it starts and hands the plan to the
  /// native engine (or turns cluster mode off for it). Returns the number of
  /// workers used; throws with a readable message if the model won't fit
  /// or a worker can't be reached.
  ///
  /// If the model fits on this phone, asks whether to keep it here (faster:
  /// no Wi-Fi in the loop) or share it with the workers anyway. Otherwise
  /// the fastest phones are filled first, up to their free memory: phones
  /// take turns on every token, so the most work belongs on the fastest one,
  /// and phones that aren't needed are left out (one less Wi-Fi hop each).
  Future<int> applyForNextLoad(String modelPath, {String? modelName}) async {
    split.clear();
    if (!isSupported) return 0;
    if (!enabled.value || workers.isEmpty) {
      await LlamaCluster.clear();
      return 0;
    }

    // Workers that are off or away are left out, not fatal: the model may
    // fit without them.
    final offline = await relocateWorkers();
    final available = workers.where((w) => !offline.any((o) => o.endpoint == w.endpoint)).toList();
    if (offline.isNotEmpty) {
      final names = offline.map((w) => w.model ?? w.name).join(', ');
      showToast('Phone cluster', 'Not reachable, loading without: $names');
    }

    final modelMb = await File(modelPath).length() / (1024 * 1024);
    final needMb = modelMb * 1.1; // + KV cache and working buffers
    _localSpeed ??= isDesktop
        ? await _desktopWorker.benchmark()
        : await LlamaCluster.benchmark();
    final localFreeMb = isDesktop
        ? (worker.value.ramMb > 0
            ? worker.value.ramMb
            : (await _desktopWorker.getStatus()).ramMb)
        : await LlamaCluster.localFreeRamMb();
    // Free RAM: workers report theirs when they start. The master also runs
    // the app and the KV cache, so it offers less of its own.
    final master = _Phone(null, localFreeMb * 0.7, _localSpeed!);
    final phones = [
      master,
      for (final w in available)
        _Phone(w, (w.ramMb ?? 2000) * 0.75, w.bandwidth ?? _unknownSpeed),
    ];
    final totalMb = phones.fold<double>(0, (a, p) => a + p.capacityMb);
    if (needMb > totalMb) {
      throw Exception('This model (${_gb(modelMb)}) is too big for these '
          '${phones.length} phones: together they have about ${_gb(totalMb)} '
          'free.${offline.isEmpty ? '' : ' Not reachable: ${offline.map((w) => w.model ?? w.name).join(', ')}.'} '
          'Add another worker, close apps on the phones, or pick a '
          'smaller model.');
    }

    if (available.isEmpty) {
      await LlamaCluster.clear();
      return 0;
    }
    if (needMb <= master.capacityMb) {
      final share = await _askFitsHere(
          modelName ?? modelPath.split('/').last, modelMb, available.length);
      if (!share) {
        await LlamaCluster.clear();
        return 0;
      }
      _splitBySpeed(phones, needMb);
    } else {
      _fillFastestFirst(phones, needMb);
    }

    final used = phones.where((p) => p.worker != null && p.assignedMb > 0).toList();
    if (used.isEmpty) {
      await LlamaCluster.clear();
      return 0;
    }
    try {
      await LlamaCluster.setCluster(
        [for (final p in used) p.worker!],
        weights: [for (final p in used) p.assignedMb],
        localWeight: master.assignedMb,
      );
    } on PlatformException catch (e) {
      throw Exception(
          '${e.message ?? 'A worker is unreachable'}. Turn on Worker on that '
          'phone, or set this phone\'s Phone cluster to Off.');
    }
    return used.length;
  }

  /// Fastest first, each up to its free memory, until the model is placed.
  static void _fillFastestFirst(List<_Phone> phones, double needMb) {
    final bySpeed = [...phones]..sort((a, b) => b.speed.compareTo(a.speed));
    var left = needMb;
    for (final p in bySpeed) {
      p.assignedMb = math.min(p.capacityMb, left);
      left -= p.assignedMb;
    }
  }

  /// Shares in proportion to speed, capped at each phone's free memory
  /// (what a capped phone can't take goes to the others).
  static void _splitBySpeed(List<_Phone> phones, double needMb) {
    var open = [...phones];
    var left = needMb;
    while (open.isNotEmpty && left > 0.5) {
      final speedSum = open.fold<double>(0, (a, p) => a + p.speed);
      final capped = [
        for (final p in open)
          if (p.assignedMb + left * p.speed / speedSum >= p.capacityMb) p,
      ];
      if (capped.isEmpty) {
        for (final p in open) {
          p.assignedMb += left * p.speed / speedSum;
        }
        left = 0;
      } else {
        for (final p in capped) {
          left -= p.capacityMb - p.assignedMb;
          p.assignedMb = p.capacityMb;
        }
        open = open.where((p) => !capped.contains(p)).toList();
      }
    }
  }

  /// LiteRT models can't be split across phones (the cluster is llama.cpp).
  /// When this phone is a master with workers, asks before loading one here
  /// alone. True to go ahead.
  Future<bool> confirmLiteRtRunsHere(String model) async {
    final context = Get.context;
    if (role != ClusterRole.master || workers.isEmpty || context == null) return true;
    final go = await showAppSheet<bool>(
      context,
      title: 'This model can\'t use your workers',
      subtitle: '${model.replaceAll(RegExp(r'\.(litertlm|task)$'), '')} is a LiteRT '
          'model, and only GGUF models can be shared across phones. It will run '
          'on this phone only. To use your workers, load a GGUF model instead.',
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PrimaryButton(
            label: 'Load on this phone only',
            icon: Icons.smartphone_rounded,
            onPressed: () => Navigator.pop(ctx, true),
          ),
          const SizedBox(height: 10),
          TonalButton.neutral(ctx, label: 'Cancel', onTap: () => Navigator.pop(ctx, false)),
        ],
      ),
    );
    return go == true;
  }

  /// "Fits on this phone" sheet. True to share with workers anyway.
  Future<bool> _askFitsHere(String model, double modelMb, int workerCount) async {
    final context = Get.context;
    if (context == null) return false;
    final share = await showAppSheet<bool>(
      context,
      title: 'This model fits on this phone',
      subtitle: '${model.replaceAll(RegExp(r'\.gguf$'), '')} needs about '
          '${_gb(modelMb)}, and this phone has room for it. Running it here '
          'is faster, because sharing sends every word over Wi-Fi. Share it '
          'to free up memory on this phone.',
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PrimaryButton(
            label: 'Load on this phone only',
            icon: Icons.smartphone_rounded,
            onPressed: () => Navigator.pop(ctx, false),
          ),
          const SizedBox(height: 10),
          TonalButton.neutral(
            ctx,
            label: 'Share with $workerCount worker${workerCount == 1 ? '' : 's'}',
            onTap: () => Navigator.pop(ctx, true),
          ),
        ],
      ),
    );
    return share == true;
  }

  /// Reads where the model actually went after a cluster load. Workers'
  /// shares come from llama.cpp's per-device weight buffers; this phone's
  /// share is the rest of the file, because its own buffers overlap (the
  /// mapped file and the CPU's repacked copy of the same weights).
  Future<void> refreshSplit(String modelPath, {int totalLayers = 32}) async {
    final buffers = await LlamaCluster.lastLoadBuffers();
    final remote = <String, ({double mb, String endpoint})>{};
    for (final b in buffers) {
      final open = b.name.indexOf('[');
      if (open < 0) continue;
      final endpoint = b.name.substring(open + 1, b.name.lastIndexOf(']'));
      final name = workers.firstWhereOrNull((w) => w.endpoint == endpoint)?.model ?? endpoint;
      final prevMb = remote[name]?.mb ?? 0.0;
      remote[name] = (mb: prevMb + b.mb, endpoint: endpoint);
    }
    final fileMb = await File(modelPath).length() / (1024 * 1024);
    final remoteMb = remote.values.fold<double>(0, (a, b) => a + b.mb);
    final masterMb = math.max(0.0, fileMb - remoteMb);
    final totalMb = masterMb + remoteMb;

    final shares = <ClusterShare>[];
    var currentLayer = 0;

    if (remote.isEmpty) {
      shares.add(ClusterShare(
        deviceName.isEmpty ? (isDesktop ? 'This PC' : 'This phone') : deviceName,
        masterMb,
        isThisPhone: true,
        startLayer: 0,
        endLayer: totalLayers - 1,
        endpoint: wifiAddress.value != null ? '${wifiAddress.value}:50052' : '127.0.0.1:50052',
        isHealthy: true,
      ));
    } else {
      final masterRatio = totalMb > 0 ? (masterMb / totalMb) : 0.5;
      final masterLayers = math.max(1, (masterRatio * totalLayers).round());
      final masterEnd = math.min(totalLayers - 1, currentLayer + masterLayers - 1);

      shares.add(ClusterShare(
        deviceName.isEmpty ? (isDesktop ? 'This PC' : 'This phone') : deviceName,
        masterMb,
        isThisPhone: true,
        startLayer: currentLayer,
        endLayer: masterEnd,
        endpoint: wifiAddress.value != null ? '${wifiAddress.value}:50052' : '127.0.0.1:50052',
        isHealthy: true,
      ));
      currentLayer = masterEnd + 1;

      final remoteEntries = remote.entries.toList();
      for (var i = 0; i < remoteEntries.length; i++) {
        final e = remoteEntries[i];
        final isLast = i == remoteEntries.length - 1;
        final wMb = e.value.mb;
        final int wLayers;
        if (isLast) {
          wLayers = math.max(1, totalLayers - currentLayer);
        } else {
          final wRatio = totalMb > 0 ? (wMb / totalMb) : 0.0;
          final calculated = (wRatio * totalLayers).round();
          wLayers = math.max(1, math.min(calculated, totalLayers - currentLayer));
        }
        final wEnd = math.min(totalLayers - 1, currentLayer + wLayers - 1);

        shares.add(ClusterShare(
          e.key,
          wMb,
          isThisPhone: false,
          startLayer: currentLayer,
          endLayer: wEnd,
          endpoint: e.value.endpoint,
          isHealthy: true,
        ));
        currentLayer = wEnd + 1;
      }
    }

    split.assignAll(shares);
    _startMasterKeepalive();
  }

  /// Tests TCP connection to a worker endpoint and measures round-trip time.
  Future<int?> pingWorker(String host, int port,
      {Duration timeout = const Duration(milliseconds: 1200)}) async {
    final sw = Stopwatch()..start();
    try {
      final socket = await Socket.connect(host, port, timeout: timeout);
      sw.stop();
      socket.destroy();
      return sw.elapsedMilliseconds;
    } catch (_) {
      return null;
    }
  }

  void _startMasterKeepalive() {
    _keepaliveTimer?.cancel();
    _keepaliveTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (role != ClusterRole.master || split.isEmpty) {
        _keepaliveTimer?.cancel();
        _keepaliveTimer = null;
        return;
      }
      final remoteShares =
          split.where((s) => !s.isThisPhone && s.endpoint.isNotEmpty).toList();
      if (remoteShares.isEmpty) {
        clusterLatencyMs.value = 0;
        isClusterHealthy.value = true;
        droppedWorkers.clear();
        return;
      }

      final pings = <int>[];
      final newlyDropped = <String>[];

      for (var i = 0; i < split.length; i++) {
        final share = split[i];
        if (share.isThisPhone || share.endpoint.isEmpty) continue;

        final parts = share.endpoint.split(':');
        final host = parts[0];
        final port = parts.length > 1
            ? int.tryParse(parts[1]) ?? LlamaCluster.defaultPort
            : LlamaCluster.defaultPort;

        final ms = await pingWorker(host, port);
        workerPings[share.endpoint] = ms;

        if (ms != null) {
          _workerFailCounts[share.endpoint] = 0;
          pings.add(ms);
          if (!share.isHealthy || share.pingMs != ms) {
            split[i] = share.copyWith(isHealthy: true, pingMs: ms);
          }
        } else {
          final fails = (_workerFailCounts[share.endpoint] ?? 0) + 1;
          _workerFailCounts[share.endpoint] = fails;
          if (fails >= 2) {
            newlyDropped.add(share.endpoint);
            if (share.isHealthy) {
              split[i] = share.copyWith(isHealthy: false, pingMs: null);
            }
          }
        }
      }

      droppedWorkers.assignAll(newlyDropped);
      isClusterHealthy.value = newlyDropped.isEmpty;
      if (pings.isNotEmpty) {
        clusterLatencyMs.value =
            (pings.reduce((a, b) => a + b) / pings.length).round();
      }
    });
  }

  void _stopMasterKeepalive() {
    _keepaliveTimer?.cancel();
    _keepaliveTimer = null;
  }

  void clearSplit() {
    _stopMasterKeepalive();
    split.clear();
    workerPings.clear();
    droppedWorkers.clear();
    clusterLatencyMs.value = 0;
    isClusterHealthy.value = true;
  }

  /// Manually pings all active remote workers and updates telemetry.
  Future<void> retestPings() async {
    final remoteShares =
        split.where((s) => !s.isThisPhone && s.endpoint.isNotEmpty).toList();
    if (remoteShares.isEmpty) {
      clusterLatencyMs.value = 0;
      isClusterHealthy.value = true;
      droppedWorkers.clear();
      return;
    }

    final pings = <int>[];
    final newlyDropped = <String>[];

    for (var i = 0; i < split.length; i++) {
      final share = split[i];
      if (share.isThisPhone || share.endpoint.isEmpty) continue;

      final parts = share.endpoint.split(':');
      final host = parts[0];
      final port = parts.length > 1
          ? int.tryParse(parts[1]) ?? LlamaCluster.defaultPort
          : LlamaCluster.defaultPort;

      final ms = await pingWorker(host, port);
      workerPings[share.endpoint] = ms;

      if (ms != null) {
        _workerFailCounts[share.endpoint] = 0;
        pings.add(ms);
        split[i] = share.copyWith(isHealthy: true, pingMs: ms);
      } else {
        newlyDropped.add(share.endpoint);
        split[i] = share.copyWith(isHealthy: false, pingMs: null);
      }
    }

    droppedWorkers.assignAll(newlyDropped);
    isClusterHealthy.value = newlyDropped.isEmpty;
    if (pings.isNotEmpty) {
      clusterLatencyMs.value =
          (pings.reduce((a, b) => a + b) / pings.length).round();
    }
  }

  /// Gracefully falls back from a degraded cluster to local execution on master.
  Future<bool> fallbackToLocal() async {
    try {
      activeDesktopClusterEndpoints.clear();
      activeDesktopClusterWeights.clear();
      await LlamaCluster.clear();
      clearSplit();
      if (Get.isRegistered<InferenceService>()) {
        final inf = Get.find<InferenceService>();
        final loadedModel = inf.loadedModelName.value;
        if (loadedModel.isNotEmpty && Get.isRegistered<ModelController>()) {
          final modelCtrl = Get.find<ModelController>();
          final path = await modelCtrl.modelPath(loadedModel);
          if (path.isNotEmpty) {
            await inf.loadModel(path, modelName: loadedModel);
          }
        }
      }
      return true;
    } catch (e) {
      Get.find<AppLogService>().error('Fallback to local failed', details: e);
      return false;
    }
  }

  /// Runs comprehensive LAN network, port 50052, and hardware diagnostics.
  Future<ClusterDiagnosticsReport> runDiagnostics() async {
    await refreshWifiAddress();
    final lanIp = wifiAddress.value;
    final hasLan = lanIp != null && lanIp.isNotEmpty;

    final adapters = <String>[];
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) {
            adapters.add('${iface.name}: ${addr.address}');
          }
        }
      }
    } catch (_) {}

    bool isPortAvailable = false;
    final isRunning = worker.value.running;
    if (isRunning) {
      isPortAvailable = true;
    } else {
      try {
        final server = await ServerSocket.bind(InternetAddress.anyIPv4, LlamaCluster.defaultPort);
        await server.close();
        isPortAvailable = true;
      } catch (_) {
        isPortAvailable = false;
      }
    }

    final speed = isDesktop
        ? await _desktopWorker.benchmark()
        : await LlamaCluster.benchmark();

    final freeRam = isDesktop
        ? (worker.value.ramMb > 0
            ? worker.value.ramMb
            : (await _desktopWorker.getStatus()).ramMb)
        : await LlamaCluster.localFreeRamMb();

    String? workerBin;
    String? masterBin;
    if (isDesktop) {
      workerBin = await _desktopWorker.findRpcServerBinary();
      masterBin = await DesktopInferenceEngine().findServerBinary();
    }

    final hasWorker = !isDesktop || workerBin != null;
    final hasMaster = !isDesktop || masterBin != null;
    final ready = hasLan && isPortAvailable && hasWorker;

    String summary;
    if (!hasLan) {
      summary = 'No active LAN IP found. Connect to Wi-Fi or local Ethernet.';
    } else if (!isPortAvailable) {
      summary = 'Port 50052 is blocked or occupied by another application.';
    } else if (isDesktop && !hasWorker) {
      summary = 'rpc-server binary is missing. Run installer in Cluster view.';
    } else {
      summary = 'Ready for LAN distributed model offloading on port 50052.';
    }

    return ClusterDiagnosticsReport(
      hasLanIp: hasLan,
      lanIp: lanIp,
      isPort50052Available: isPortAvailable,
      isWorkerRunning: isRunning,
      hasWorkerBinary: hasWorker,
      workerBinaryPath: workerBin,
      hasMasterBinary: hasMaster,
      masterBinaryPath: masterBin,
      memoryBandwidthGbps: speed,
      freeRamMb: freeRam,
      networkAdapters: adapters,
      statusSummary: summary,
      isReady: ready,
    );
  }

  static String _gb(double mb) => '${(mb / 1024).toStringAsFixed(1)} GB';
}
