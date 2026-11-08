import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';
import 'package:privatelm/services/cluster_service.dart';
import 'package:privatelm/services/desktop_inference_engine.dart';
import 'package:privatelm/services/desktop_rpc_worker.dart';
import 'package:privatelm/services/desktop_engine_manager.dart';
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

    test('buildServerArgs generates expected default flags', () {
      final args = DesktopInferenceEngine.buildServerArgs(
        modelPath: 'C:/models/qwen2.5-7b.gguf',
        contextSize: 8192,
        threads: 8,
        port: 50051,
      );

      expect(args, contains('-m'));
      expect(args, contains('C:/models/qwen2.5-7b.gguf'));
      expect(args, contains('-c'));
      expect(args, contains('8192'));
      expect(args, contains('-t'));
      expect(args, contains('8'));
      expect(args, contains('-fa'));
      expect(args.contains('-ctk'), isFalse);
      expect(args.contains('-ctv'), isFalse);
    });

    test('buildServerArgs appends -ctk and -ctv flags for quantized KV cache', () {
      final args = DesktopInferenceEngine.buildServerArgs(
        modelPath: 'C:/models/llama-3.1-8b.gguf',
        kvCacheTypeK: 'q8_0',
        kvCacheTypeV: 'q8_0',
        gpuLayers: 33,
        clusterEndpoints: ['192.168.1.150:50052', '192.168.1.151:50052'],
      );

      expect(args, contains('-ctk'));
      final ctkIndex = args.indexOf('-ctk');
      expect(args[ctkIndex + 1], 'q8_0');

      expect(args, contains('-ctv'));
      final ctvIndex = args.indexOf('-ctv');
      expect(args[ctvIndex + 1], 'q8_0');

      expect(args, contains('-ngl'));
      expect(args, contains('33'));

      expect(args, contains('--rpc'));
      expect(args, contains('192.168.1.150:50052,192.168.1.151:50052'));
    });

    test('buildServerArgs ignores -ctk and -ctv when set to f16 (standard unquantized)', () {
      final args = DesktopInferenceEngine.buildServerArgs(
        modelPath: 'C:/models/model.gguf',
        kvCacheTypeK: 'f16',
        kvCacheTypeV: 'f16',
      );

      expect(args.contains('-ctk'), isFalse);
      expect(args.contains('-ctv'), isFalse);
    });
  });

  group('GallerySaver Cross-Platform Tests', () {
    test('Non-existent file returns false safely without throwing', () async {
      final result = await GallerySaver.saveImage('/non/existent/path/to/test.png');
      expect(result, isFalse);
    });
  });

  group('Cluster Diagnostics Report Tests', () {
    test('Diagnostics report initializes with correct flags', () {
      const report = ClusterDiagnosticsReport(
        hasLanIp: true,
        lanIp: '192.168.1.100',
        isPort50052Available: true,
        isWorkerRunning: false,
        hasWorkerBinary: true,
        workerBinaryPath: 'bin/rpc-server.exe',
        hasMasterBinary: true,
        masterBinaryPath: 'bin/llama-server.exe',
        memoryBandwidthGbps: 34.5,
        freeRamMb: 16384,
        networkAdapters: ['Wi-Fi: 192.168.1.100'],
        statusSummary: 'Ready for LAN distributed model offloading on port 50052.',
        isReady: true,
      );

      expect(report.isReady, isTrue);
      expect(report.lanIp, '192.168.1.100');
      expect(report.isPort50052Available, isTrue);
      expect(report.memoryBandwidthGbps, 34.5);
      expect(report.hasWorkerBinary, isTrue);
    });
  });

  group('Desktop Engine Manager & Hardware Detection Tests', () {
    test('DesktopEngineManager binary names match platform conventions', () {
      if (Platform.isWindows) {
        expect(DesktopEngineManager.masterBinaryName, 'llama-server.exe');
        expect(DesktopEngineManager.workerBinaryName, 'rpc-server.exe');
      } else {
        expect(DesktopEngineManager.masterBinaryName, 'llama-server');
        expect(DesktopEngineManager.workerBinaryName, 'rpc-server');
      }
    });

    test('EngineBinaryStatus correctly reports state and summaries', () {
      const readyStatus = EngineBinaryStatus(
        hasMaster: true,
        hasWorker: true,
        masterPath: 'bin/llama-server.exe',
        workerPath: 'bin/rpc-server.exe',
        binDirectory: 'bin',
      );
      expect(readyStatus.isFullyReady, isTrue);
      expect(readyStatus.summary, 'Master & RPC worker operational');

      const missingWorker = EngineBinaryStatus(
        hasMaster: true,
        hasWorker: false,
        binDirectory: 'bin',
      );
      expect(missingWorker.isFullyReady, isFalse);
      expect(missingWorker.summary, 'Master ready (rpc-server missing)');

      const noneStatus = EngineBinaryStatus(
        hasMaster: false,
        hasWorker: false,
        binDirectory: 'bin',
      );
      expect(noneStatus.isFullyReady, isFalse);
      expect(noneStatus.summary, 'Engine binaries not installed');
    });

    test('EngineBackendFlavor exposes expected display and short names', () {
      expect(EngineBackendFlavor.vulkan.shortName, 'Vulkan GPU');
      expect(EngineBackendFlavor.cuda12.shortName, 'CUDA 12');
      expect(EngineBackendFlavor.cpu.shortName, 'CPU (AVX2)');
      expect(EngineBackendFlavor.vulkan.displayName, contains('Vulkan GPU'));
      expect(EngineBackendFlavor.cuda12.displayName, contains('CUDA 12'));
    });

    test('GpuDetectionResult preserves vendor, recommended flavor and flags', () {
      const detection = GpuDetectionResult(
        vendor: GpuVendor.amd,
        gpuName: 'AMD Radeon RX 6600',
        hasVulkan: true,
        hasNvidiaSmi: false,
        recommendedFlavor: EngineBackendFlavor.vulkan,
        recommendationReason: 'AMD GPU detected',
      );

      expect(detection.vendor, GpuVendor.amd);
      expect(detection.gpuName, 'AMD Radeon RX 6600');
      expect(detection.hasVulkan, isTrue);
      expect(detection.hasNvidiaSmi, isFalse);
      expect(detection.recommendedFlavor, EngineBackendFlavor.vulkan);
    });
  });
}
