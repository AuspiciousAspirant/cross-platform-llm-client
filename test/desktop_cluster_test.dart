import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';
import 'package:privatelm/services/desktop_inference_engine.dart';
import 'package:privatelm/services/desktop_rpc_worker.dart';
import 'package:privatelm/utils/gallery_saver.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Desktop Cluster Worker Model Tests', () {
    test('ClusterWorker creates valid endpoint string', () {
      const worker = ClusterWorker(
        name: 'Gaming-PC',
        host: '192.168.1.50',
        port: 50052,
        ramMb: 32000,
        bandwidth: 48.5,
      );

      expect(worker.endpoint, '192.168.1.50:50052');
      expect(worker.ramMb, 32000);
      expect(worker.bandwidth, 48.5);
    });

    test('ClusterWorker serialization round-trip', () {
      final map = {
        'name': 'Workstation',
        'host': '192.168.1.120',
        'port': 50052,
        'ramMb': 64000,
        'bandwidth': 65.0,
        'model': 'RTX 4090',
        'id': 'pc-uuid-1234',
      };

      final worker = ClusterWorker.fromMap(map);
      expect(worker.name, 'Workstation');
      expect(worker.host, '192.168.1.120');
      expect(worker.port, 50052);
      expect(worker.ramMb, 64000);
      expect(worker.bandwidth, 65.0);
      expect(worker.model, 'RTX 4090');
      expect(worker.id, 'pc-uuid-1234');

      final serialized = worker.toMap();
      expect(serialized['name'], 'Workstation');
      expect(serialized['host'], '192.168.1.120');
      expect(serialized['id'], 'pc-uuid-1234');
    });

    test('ClusterWorker movedTo preserves identity with new IP', () {
      const original = ClusterWorker(
        name: 'Work-Laptop',
        host: '192.168.1.15',
        port: 50052,
        ramMb: 16000,
        bandwidth: 22.0,
        id: 'laptop-99',
      );

      final moved = original.movedTo('192.168.1.88', 50052);
      expect(moved.host, '192.168.1.88');
      expect(moved.id, 'laptop-99');
      expect(moved.ramMb, 16000);
    });

    test('ClusterWorkerStatus states behave correctly', () {
      const runningStatus = ClusterWorkerStatus(
        state: 'running',
        peer: '192.168.1.10',
        heldMb: 4096,
        ramMb: 32000,
      );
      expect(runningStatus.running, isTrue);
      expect(runningStatus.starting, isFalse);
      expect(runningStatus.heldMb, 4096);

      const stoppedStatus = ClusterWorkerStatus(state: 'stopped');
      expect(stoppedStatus.running, isFalse);
    });
  });

  group('Desktop Inference Engine Tests', () {
    test('Correct binary name per operating system', () {
      if (Platform.isWindows) {
        expect(DesktopInferenceEngine.binaryName, 'llama-server.exe');
        expect(DesktopRpcWorker.binaryName, 'rpc-server.exe');
      } else {
        expect(DesktopInferenceEngine.binaryName, 'llama-server');
        expect(DesktopRpcWorker.binaryName, 'rpc-server');
      }
    });

    test('DesktopLoadResult initializes with expected defaults', () {
      final res = DesktopLoadResult(
        success: true,
        message: 'Model loaded',
        gpuName: 'Vulkan GPU',
        gpuLayers: 33,
      );

      expect(res.success, isTrue);
      expect(res.runtime, 'llama');
      expect(res.backend, 'cpu'); // default unless overridden
      expect(res.gpuLayers, 33);
      expect(res.gpuName, 'Vulkan GPU');
    });
  });

  group('GallerySaver Cross-Platform Tests', () {
    test('Non-existent file returns false safely without throwing', () async {
      final result = await GallerySaver.saveImage('/non/existent/path/to/test.png');
      expect(result, isFalse);
    });
  });
}
