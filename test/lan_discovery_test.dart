import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';
import 'package:privatelm/services/lan_cluster_discovery.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LanClusterDiscovery Packet & Serialization Tests', () {
    test('buildBeaconData creates compliant JSON beacon payload', () {
      const worker = ClusterWorker(
        name: 'MacBook-Pro',
        host: '192.168.1.100',
        port: 50052,
        ramMb: 32768,
        bandwidth: 55.4,
        model: 'Apple M3 Max',
        id: 'mbp-uuid-999',
      );

      final data = LanClusterDiscovery.buildBeaconData(worker);

      expect(data['type'], LanClusterDiscovery.packetType);
      expect(data['type'], 'privatelm_worker');
      expect(data['id'], 'mbp-uuid-999');
      expect(data['name'], 'MacBook-Pro');
      expect(data['host'], '192.168.1.100');
      expect(data['port'], 50052);
      expect(data['ramMb'], 32768);
      expect(data['bandwidth'], 55.4);
      expect(data['model'], 'Apple M3 Max');
    });

    test('encodeBeacon produces valid UTF-8 JSON datagram bytes', () {
      const worker = ClusterWorker(
        name: 'Gaming-Rig',
        host: '192.168.1.42',
        port: 50052,
        ramMb: 65536,
        bandwidth: 72.8,
        model: 'RTX 4090 Desktop',
        id: 'desktop-rig-01',
      );

      final bytes = LanClusterDiscovery.encodeBeacon(worker);
      expect(bytes, isA<Uint8List>());
      expect(bytes.isNotEmpty, isTrue);

      final decodedStr = utf8.decode(bytes);
      final jsonMap = jsonDecode(decodedStr) as Map<String, dynamic>;

      expect(jsonMap['type'], 'privatelm_worker');
      expect(jsonMap['host'], '192.168.1.42');
      expect(jsonMap['port'], 50052);
      expect(jsonMap['ramMb'], 65536);
      expect(jsonMap['model'], 'RTX 4090 Desktop');
    });
  });

  group('LanClusterDiscovery Deserialization & Parsing Tests', () {
    test('parseBeacon correctly parses full worker dictionary', () {
      final payload = {
        'type': 'privatelm_worker',
        'id': 'worker-node-abc',
        'name': 'Linux-Server',
        'host': '192.168.1.200',
        'port': 50052,
        'ramMb': 16384,
        'bandwidth': 24.5,
        'model': 'Ubuntu 24.04 EPYC',
      };

      final worker = LanClusterDiscovery.parseBeacon(payload);
      expect(worker, isNotNull);
      expect(worker!.id, 'worker-node-abc');
      expect(worker.name, 'Linux-Server');
      expect(worker.host, '192.168.1.200');
      expect(worker.port, 50052);
      expect(worker.endpoint, '192.168.1.200:50052');
      expect(worker.ramMb, 16384);
      expect(worker.bandwidth, 24.5);
      expect(worker.model, 'Ubuntu 24.04 EPYC');
    });

    test('parseBeacon parses JSON string input', () {
      final jsonString = jsonEncode({
        'type': 'privatelm_worker',
        'id': 'win-worker-1',
        'name': 'Windows-PC',
        'host': '192.168.1.15',
        'port': 50052,
        'ramMb': 32768,
        'bandwidth': 42.0,
      });

      final worker = LanClusterDiscovery.parseBeacon(jsonString);
      expect(worker, isNotNull);
      expect(worker!.name, 'Windows-PC');
      expect(worker.host, '192.168.1.15');
      expect(worker.ramMb, 32768);
      expect(worker.bandwidth, 42.0);
    });

    test('parseDatagramBytes parses raw packet bytes with senderAddress fallback', () {
      final payload = {
        'type': 'privatelm_worker',
        'id': 'node-4',
        'host': '', // empty host should fallback to sender address
        'port': 50052,
      };

      final bytes = utf8.encode(jsonEncode(payload));
      final worker = LanClusterDiscovery.parseDatagramBytes(
        bytes,
        senderAddress: '192.168.1.77',
      );

      expect(worker, isNotNull);
      expect(worker!.host, '192.168.1.77');
      expect(worker.endpoint, '192.168.1.77:50052');
      expect(worker.name, '192.168.1.77');
    });

    test('parseBeacon rejects packets with invalid or missing type', () {
      final invalidTypePayload = {
        'type': 'some_other_protocol',
        'host': '192.168.1.99',
        'port': 50052,
      };

      expect(LanClusterDiscovery.parseBeacon(invalidTypePayload), isNull);

      final noTypePayload = {
        'host': '192.168.1.99',
        'port': 50052,
      };

      expect(LanClusterDiscovery.parseBeacon(noTypePayload), isNull);
    });

    test('parseBeacon rejects malformed JSON and non-map structures', () {
      expect(LanClusterDiscovery.parseBeacon('not a json string'), isNull);
      expect(LanClusterDiscovery.parseBeacon(12345), isNull);
      expect(LanClusterDiscovery.parseBeacon(['list', 'instead', 'of', 'map']), isNull);
    });

    test('parseBeacon handles missing host gracefully when senderAddress is absent', () {
      final payload = {
        'type': 'privatelm_worker',
        'host': '',
        'port': 50052,
      };

      expect(LanClusterDiscovery.parseBeacon(payload), isNull);
    });

    test('parseBeacon handles string or numeric port values', () {
      final numericPortPayload = {
        'type': 'privatelm_worker',
        'host': '192.168.1.5',
        'port': 50052,
      };
      expect(LanClusterDiscovery.parseBeacon(numericPortPayload)?.port, 50052);

      final stringPortPayload = {
        'type': 'privatelm_worker',
        'host': '192.168.1.5',
        'port': '50055',
      };
      expect(LanClusterDiscovery.parseBeacon(stringPortPayload)?.port, 50055);
    });
  });

  group('LanClusterDiscovery Lifecycle & State Tests', () {
    test('Initializes with stopped broadcasting and listening state', () {
      final discovery = LanClusterDiscovery();
      expect(discovery.isBroadcasting, isFalse);
      expect(discovery.isListening, isFalse);

      // Safe to call stop without starting
      discovery.stopBroadcasting();
      discovery.stopListening();
      expect(discovery.isBroadcasting, isFalse);
      expect(discovery.isListening, isFalse);

      discovery.dispose();
    });

    test('Round-trip serialization and deserialization integrity', () {
      const originalWorker = ClusterWorker(
        name: 'Device-Cluster-Alpha',
        host: '10.0.0.150',
        port: 50052,
        ramMb: 65536,
        bandwidth: 88.5,
        model: 'Server Node #1',
        id: 'node-alpha-42',
      );

      final bytes = LanClusterDiscovery.encodeBeacon(originalWorker);
      final parsedWorker = LanClusterDiscovery.parseDatagramBytes(bytes);

      expect(parsedWorker, isNotNull);
      expect(parsedWorker!.id, originalWorker.id);
      expect(parsedWorker.name, originalWorker.name);
      expect(parsedWorker.host, originalWorker.host);
      expect(parsedWorker.port, originalWorker.port);
      expect(parsedWorker.ramMb, originalWorker.ramMb);
      expect(parsedWorker.bandwidth, originalWorker.bandwidth);
      expect(parsedWorker.model, originalWorker.model);
      expect(parsedWorker.endpoint, originalWorker.endpoint);
    });
  });
}
