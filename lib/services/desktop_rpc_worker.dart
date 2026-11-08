import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:llama_flutter_android/llama_flutter_android.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'app_log_service.dart';
import 'device_info_native.dart' as platform_info;
import 'device_info_service.dart';
import 'hive_service.dart';

/// Native desktop RPC worker manager for Windows, macOS, and Linux.
///
/// Spawns and supervises llama.cpp's `rpc-server` executable so any PC
/// running PrivateLM can act as a high-performance LAN cluster worker.
class DesktopRpcWorker {
  static const String llamaCppReleasesUrl =
      'https://github.com/ggerganov/llama.cpp/releases';
  static const String llamaCppLatestApiUrl =
      'https://api.github.com/repos/ggerganov/llama.cpp/releases/latest';

  Process? _process;

  /// Worker lifecycle state: 'stopped', 'starting', 'running', 'error'.
  String state = 'stopped';
  String? error;
  String? peer;
  int heldMb = 0;
  double bandwidth = 0.0;

  String? _workerId;
  String? _resolvedBinaryPath;

  bool get isRunning => state == 'running';
  String? get currentPeer => peer;
  String? get binaryPath => _resolvedBinaryPath;

  static String get binaryName =>
      Platform.isWindows ? 'rpc-server.exe' : 'rpc-server';

  /// Preferred local directory for tool binaries: `<project>/bin` or `<appSupport>/bin`.
  static Future<String> getPreferredBinDir() async {
    try {
      final projectBin = Directory(p.join(Directory.current.path, 'bin'));
      if (await projectBin.exists()) return projectBin.path;
    } catch (_) {}

    try {
      final appSupport = await getApplicationSupportDirectory();
      final appBin = Directory(p.join(appSupport.path, 'bin'));
      if (!await appBin.exists()) {
        await appBin.create(recursive: true);
      }
      return appBin.path;
    } catch (_) {
      return p.join(Directory.current.path, 'bin');
    }
  }

  /// Searches for `rpc-server.exe` (or `rpc-server` on Linux/macOS) in:
  /// 1) Alongside executable: `p.join(p.dirname(Platform.resolvedExecutable), 'rpc-server.exe')`
  /// 2) In project root / local tools: `p.join(Directory.current.path, 'bin', 'rpc-server.exe')`
  /// 3) In system PATH (via `where.exe` or `which`)
  /// 4) In application support tools directory
  Future<String?> findRpcServerBinary() async {
    final bin = binaryName;

    // 1) Alongside the executable:
    try {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      final c1 = p.join(exeDir, bin);
      if (await File(c1).exists()) {
        _resolvedBinaryPath = c1;
        return c1;
      }
      final c1b = p.join(exeDir, 'bin', bin);
      if (await File(c1b).exists()) {
        _resolvedBinaryPath = c1b;
        return c1b;
      }
    } catch (_) {}

    // 2) In project root / local tools:
    try {
      final c2 = p.join(Directory.current.path, 'bin', bin);
      if (await File(c2).exists()) {
        _resolvedBinaryPath = c2;
        return c2;
      }
      final c2b = p.join(Directory.current.path, bin);
      if (await File(c2b).exists()) {
        _resolvedBinaryPath = c2b;
        return c2b;
      }
    } catch (_) {}

    // 3) In system PATH:
    try {
      final cmd = Platform.isWindows ? 'where.exe' : 'which';
      final res = await Process.run(cmd, [bin]);
      if (res.exitCode == 0) {
        final lines = (res.stdout as String)
            .split(RegExp(r'\r?\n'))
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        for (final line in lines) {
          if (await File(line).exists()) {
            _resolvedBinaryPath = line;
            return line;
          }
        }
      }
    } catch (_) {}

    // 3b) Environment PATH scan fallback:
    try {
      final pathEnv = Platform.environment['PATH'] ?? '';
      final sep = Platform.isWindows ? ';' : ':';
      for (final dir in pathEnv.split(sep)) {
        final d = dir.trim();
        if (d.isEmpty) continue;
        final candidate = p.join(d, bin);
        if (await File(candidate).exists()) {
          _resolvedBinaryPath = candidate;
          return candidate;
        }
      }
    } catch (_) {}

    // 4) Application support bin folder:
    try {
      final appSupport = await getApplicationSupportDirectory();
      final c4 = p.join(appSupport.path, 'bin', bin);
      if (await File(c4).exists()) {
        _resolvedBinaryPath = c4;
        return c4;
      }
    } catch (_) {}

    _resolvedBinaryPath = null;
    return null;
  }

  /// Spawns the `rpc-server` process with arguments:
  /// `['-H', '0.0.0.0', '-p', '$port', if (threads != null) ...['-c', '$threads']]`
  Future<void> start({int port = 50052, int? threads}) async {
    final binary = await findRpcServerBinary();
    if (binary == null) {
      state = 'error';
      error =
          'rpc-server binary not found. Please place $binaryName in the bin/ directory.';
      throw Exception(error);
    }

    if (_process != null) {
      await stop();
    }

    state = 'starting';
    error = null;
    peer = null;
    heldMb = 0;

    final args = [
      '-H',
      '0.0.0.0',
      '-p',
      '$port',
      if (threads != null) ...['-c', '$threads'],
    ];

    try {
      _process = await Process.start(binary, args);
      _log('Spawned $binary with args: ${args.join(' ')}');
    } catch (e) {
      state = 'error';
      error = 'Failed to spawn $binary: $e';
      _logError(error!);
      rethrow;
    }

    // Hook stdout and stderr
    _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
      _handleOutputLine,
      onError: (err) {
        state = 'error';
        error = err.toString();
        _logError('Process stdout error: $err');
      },
    );

    _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
      _handleOutputLine,
      onError: (err) {
        state = 'error';
        error = err.toString();
        _logError('Process stderr error: $err');
      },
    );

    // Watch process termination
    _process!.exitCode.then((code) {
      _log('Process exited with code $code');
      if (state != 'stopped') {
        state = code == 0 ? 'stopped' : 'error';
        if (code != 0 && error == null) {
          error = 'Worker exited unexpectedly with code $code';
        }
      }
      _process = null;
      peer = null;
    });

    // Short startup grace period to detect immediate port bind issues
    await Future.delayed(const Duration(milliseconds: 300));
    if (state == 'starting' && _process != null) {
      state = 'running';
    }
  }

  void _handleOutputLine(String rawLine) {
    final line = rawLine.trim();
    if (line.isEmpty) return;
    _log('[rpc-server] $line');

    final lower = line.toLowerCase();

    // 1. Detect startup: e.g. "listening on 0.0.0.0:50052" or "create_backend"
    if (lower.contains('listening on') ||
        lower.contains('starting rpc server') ||
        lower.contains('create_backend') ||
        lower.contains('server listening')) {
      state = 'running';
      error = null;
    }

    // 2. Detect master connection: e.g. "RPC client connected: 192.168.1.100" or "client connected from 192.168.1.100"
    if (lower.contains('client connected') ||
        lower.contains('connection from') ||
        lower.contains('accepted connection')) {
      final ipMatch = RegExp(
              r'(?:from\s+|:\s*|\b)([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})')
          .firstMatch(line);
      if (ipMatch != null) {
        peer = ipMatch.group(1);
      } else {
        peer = 'Master (connected)';
      }
      state = 'running';
    }

    // 3. Detect disconnect: e.g. "RPC client disconnected" or "Connection closed"
    if (lower.contains('client disconnected') ||
        lower.contains('connection closed') ||
        lower.contains('client left') ||
        (lower.contains('disconnected') && !lower.contains('disconnected from'))) {
      peer = null;
    }

    // 4. Detect errors
    if (lower.contains('address already in use') ||
        lower.contains('failed to bind') ||
        lower.contains('bind error') ||
        lower.contains('fatal:') ||
        lower.startsWith('error:') ||
        lower.contains(' error: ')) {
      state = 'error';
      error = line;
    }

    // 5. Detect memory / buffer usage if printed by rpc-server
    final memMatch = RegExp(
            r'(?:allocat\w+|buffer|held|memory)\D*(\d+)\s*(?:mb|megabytes)',
            caseSensitive: false)
        .firstMatch(line);
    if (memMatch != null) {
      final mb = int.tryParse(memMatch.group(1)!);
      if (mb != null && mb > 0) {
        heldMb = mb;
      }
    }
  }

  /// Sends SIGTERM or `_process?.kill()`, sets `state = 'stopped'`, `peer = null`.
  Future<void> stop() async {
    state = 'stopped';
    peer = null;
    heldMb = 0;
    error = null;
    final proc = _process;
    if (proc != null) {
      _process = null;
      try {
        proc.kill(ProcessSignal.sigterm);
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 250));
      try {
        proc.kill(ProcessSignal.sigkill);
      } catch (_) {}
    }
  }

  /// Returns `ClusterWorkerStatus` using free RAM, current state, peer, bandwidth, lasting device worker ID.
  Future<ClusterWorkerStatus> getStatus() async {
    int ramMb = 0;
    try {
      if (Get.isRegistered<DeviceInfoService>()) {
        final dev = Get.find<DeviceInfoService>();
        if (dev.availableRamGB.value > 0) {
          ramMb = (dev.availableRamGB.value * 1024).round();
        }
      }
      if (ramMb == 0) {
        final info = await platform_info.getDeviceInfo();
        final avail = (info['availableRamGB'] as num?)?.toDouble() ?? 8.0;
        ramMb = (avail * 1024).round();
      }
    } catch (_) {
      ramMb = 8192; // safe fallback on PC
    }

    if (bandwidth <= 0.0) {
      try {
        bandwidth = await benchmark();
      } catch (_) {
        bandwidth = 15.0; // typical desktop RAM speed
      }
    }

    final id = await getWorkerId();

    return ClusterWorkerStatus(
      state: state,
      error: error,
      peer: peer,
      heldMb: heldMb,
      ramMb: ramMb,
      bandwidth: bandwidth,
      throttled: false,
      batteryUnrestricted: true,
      id: id,
    );
  }

  /// Fast Dart memory read loop benchmark to compute `bandwidth` in GB/s.
  /// Runs in an Isolate so the UI is never blocked.
  Future<double> benchmark() async {
    try {
      final gbps = await Isolate.run(_runMemoryReadBenchmark);
      bandwidth = gbps;
      return gbps;
    } catch (_) {
      final gbps = _runMemoryReadBenchmark();
      bandwidth = gbps;
      return gbps;
    }
  }

  static double _runMemoryReadBenchmark() {
    const sizeBytes = 32 * 1024 * 1024; // 32MB buffer
    final buffer = Uint8List(sizeBytes);

    // Warm-up and commit pages into RAM
    for (int i = 0; i < sizeBytes; i += 4096) {
      buffer[i] = (i & 0xFF);
    }
    final u64 = Uint64List.view(buffer.buffer);
    final len = u64.length;

    int accumulator = 0;
    for (int i = 0; i < len; i += 8) {
      accumulator += u64[i];
    }

    // Timed passes (4 iterations over 32MB = 128MB read)
    const passes = 4;
    final sw = Stopwatch()..start();
    for (int p = 0; p < passes; p++) {
      for (int i = 0; i < len; i += 8) {
        accumulator ^= u64[i] ^
            u64[i + 1] ^
            u64[i + 2] ^
            u64[i + 3] ^
            u64[i + 4] ^
            u64[i + 5] ^
            u64[i + 6] ^
            u64[i + 7];
      }
    }
    sw.stop();

    if (accumulator == 0x7FFFFFFF) debugPrint('$accumulator');

    final seconds = sw.elapsedMicroseconds / 1000000.0;
    if (seconds <= 0.0) return 15.0;
    final totalGb = (sizeBytes * passes) / (1024.0 * 1024.0 * 1024.0);
    final gbps = totalGb / seconds;
    return (gbps * 10).round() / 10.0;
  }

  /// Lasting device worker ID to find this PC again if its LAN IP changes.
  Future<String> getWorkerId() async {
    if (_workerId != null && _workerId!.isNotEmpty) return _workerId!;

    try {
      if (Get.isRegistered<HiveService>()) {
        final hive = Get.find<HiveService>();
        final id = hive.getSetting<String>('desktop_cluster_worker_id');
        if (id != null && id.isNotEmpty) {
          _workerId = id;
          return id;
        }
        final newId = const Uuid().v4();
        await hive.setSetting('desktop_cluster_worker_id', newId);
        _workerId = newId;
        return newId;
      }
    } catch (_) {}

    try {
      final appSupport = await getApplicationSupportDirectory();
      final idFile = File(p.join(appSupport.path, 'cluster_worker_id'));
      if (await idFile.exists()) {
        final content = (await idFile.readAsString()).trim();
        if (content.isNotEmpty) {
          _workerId = content;
          return content;
        }
      }
      final newId = const Uuid().v4();
      await idFile.parent.create(recursive: true);
      await idFile.writeAsString(newId);
      _workerId = newId;
      return newId;
    } catch (_) {}

    _workerId = const Uuid().v4();
    return _workerId!;
  }

  /// Downloads prebuilt `rpc-server` and essential libraries from official llama.cpp releases.
  Future<bool> downloadAndInstallRpcServer({
    void Function(double progress, String status)? onProgress,
  }) async {
    final client = http.Client();
    try {
      onProgress?.call(0.05, 'Querying latest llama.cpp release...');
      final apiUrl = Uri.parse(llamaCppLatestApiUrl);
      final res = await client.get(apiUrl, headers: {
        'User-Agent': 'PrivateLM-LLM-Client',
        'Accept': 'application/vnd.github.v3+json',
      }).timeout(const Duration(seconds: 10));

      String? downloadUrl;
      String? archiveName;

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final assets = (data['assets'] as List?)?.cast<Map<String, dynamic>>() ?? [];

        for (final asset in assets) {
          final name = (asset['name'] as String? ?? '').toLowerCase();
          final url = asset['browser_download_url'] as String?;
          if (url == null) continue;

          if (Platform.isWindows) {
            // Prefer AVX2 or general Windows x64 zip
            if (name.contains('bin-win-avx2-x64') && name.endsWith('.zip')) {
              downloadUrl = url;
              archiveName = name;
              break;
            } else if (name.contains('bin-win') && name.contains('x64') && name.endsWith('.zip')) {
              downloadUrl = url;
              archiveName = name;
            }
          } else if (Platform.isMacOS) {
            if (name.contains('bin-macos-arm64') && name.endsWith('.zip')) {
              downloadUrl = url;
              archiveName = name;
              break;
            } else if (name.contains('bin-macos') && name.endsWith('.zip')) {
              downloadUrl = url;
              archiveName = name;
            }
          } else if (Platform.isLinux) {
            if (name.contains('bin-ubuntu-x64') && name.endsWith('.zip')) {
              downloadUrl = url;
              archiveName = name;
              break;
            }
          }
        }
      }

      // If GitHub API rate-limited or asset search didn't match, fallback to releases page
      if (downloadUrl == null) {
        _logError('Could not find compatible llama.cpp binary asset automatically.');
        return false;
      }

      onProgress?.call(0.15, 'Downloading ${archiveName ?? 'llama.cpp archive'}...');
      final dlReq = http.Request('GET', Uri.parse(downloadUrl));
      final dlRes = await client.send(dlReq);

      if (dlRes.statusCode != 200) {
        throw Exception('Download returned HTTP ${dlRes.statusCode}');
      }

      final totalBytes = dlRes.contentLength ?? 0;
      final bytes = <int>[];
      int received = 0;

      await for (final chunk in dlRes.stream) {
        bytes.addAll(chunk);
        received += chunk.length;
        if (totalBytes > 0) {
          final ratio = 0.15 + (received / totalBytes) * 0.70;
          final mb = (received / (1024 * 1024)).toStringAsFixed(1);
          final totalMb = (totalBytes / (1024 * 1024)).toStringAsFixed(1);
          onProgress?.call(ratio, 'Downloading: $mb / $totalMb MB');
        }
      }

      onProgress?.call(0.88, 'Extracting rpc-server binary...');
      final archive = ZipDecoder().decodeBytes(bytes);

      final binDir = await getPreferredBinDir();
      final dir = Directory(binDir);
      if (!await dir.exists()) await dir.create(recursive: true);

      final bin = binaryName;
      bool foundServer = false;

      for (final file in archive) {
        if (!file.isFile) continue;
        final base = p.basename(file.name);

        // Extract rpc-server and llama-server executables and all supporting runtime libraries (DLLs / SOs / dylibs)
        final isServer = base.toLowerCase() == bin.toLowerCase();
        final isLlamaServer = base.toLowerCase() == 'llama-server.exe' ||
            base.toLowerCase() == 'llama-server' ||
            base.toLowerCase() == 'llama-cli.exe' ||
            base.toLowerCase() == 'llama-cli';
        final isLib = (Platform.isWindows && base.toLowerCase().endsWith('.dll')) ||
            (Platform.isLinux && base.contains('.so')) ||
            (Platform.isMacOS && base.contains('.dylib'));

        if (isServer || isLlamaServer || isLib) {
          final outFile = File(p.join(dir.path, base));
          await outFile.writeAsBytes(file.content as List<int>);
          if (isServer) {
            foundServer = true;
            if (!Platform.isWindows) {
              await Process.run('chmod', ['+x', outFile.path]);
            }
            _resolvedBinaryPath = outFile.path;
          }
        }
      }

      if (foundServer) {
        onProgress?.call(1.0, 'Installation complete!');
        state = 'stopped';
        error = null;
        return true;
      } else {
        throw Exception('Archive did not contain $bin');
      }
    } catch (e) {
      _logError('Failed to download/install rpc-server: $e');
      return false;
    } finally {
      client.close();
    }
  }

  /// Opens the official llama.cpp releases page in the user's default browser.
  static Future<void> openReleasesPage() async {
    const url = llamaCppReleasesUrl;
    try {
      if (Platform.isWindows) {
        await Process.run('cmd', ['/c', 'start', '', url]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [url]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [url]);
      }
    } catch (_) {}
  }

  /// Opens the target folder in the system file manager (Explorer / Finder / Files).
  static Future<void> openFolder(String path) async {
    try {
      final dir = Directory(path);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      if (Platform.isWindows) {
        await Process.run('explorer.exe', [path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [path]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [path]);
      }
    } catch (_) {}
  }

  void _log(String msg) {
    try {
      if (Get.isRegistered<AppLogService>()) {
        Get.find<AppLogService>().info('[DesktopRpcWorker] $msg');
      }
    } catch (_) {}
  }

  void _logError(String msg) {
    try {
      if (Get.isRegistered<AppLogService>()) {
        Get.find<AppLogService>().error('[DesktopRpcWorker] $msg');
      }
    } catch (_) {}
  }
}
