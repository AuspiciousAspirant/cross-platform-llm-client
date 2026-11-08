import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart'
    show ClusterWorker, ContextInfo, activeDesktopClusterEndpoints;
import 'package:archive/archive.dart';

import 'device_info_native.dart';

/// Result from model loading on desktop.
class DesktopLoadResult {
  final bool success;
  final String message;
  final String gpuName;
  final int gpuLayers;
  final String runtime;
  final String backend;

  DesktopLoadResult({
    required this.success,
    required this.message,
    this.gpuName = '',
    this.gpuLayers = 0,
    this.runtime = 'llama',
    this.backend = 'cpu',
  });
}

/// Desktop Inference Engine for Windows, macOS, and Linux.
///
/// Features:
/// 1. Subprocess management for `llama-server` (or `llama-cli`).
/// 2. Distributed LAN Cluster Master: Passes `--rpc worker1:port,worker2:port`
///    to offload tensor layers to remote worker nodes (phones, PCs) on LAN port 50052.
/// 3. High-performance SSE streaming via OpenAI-compatible `/v1/chat/completions` API.
/// 4. Auto-discovery of binaries in `bin/`, application directories, and PATH.
/// 5. One-click automated release downloader from official `llama.cpp` GitHub releases.
class DesktopInferenceEngine {
  static const String llamaCppLatestApiUrl =
      'https://api.github.com/repos/ggerganov/llama.cpp/releases/latest';

  Process? _process;
  http.Client? _activeClient;
  int _port = 50080;
  bool _isLoaded = false;
  String _loadedModelPath = '';
  String? _mmprojPath;
  bool _disposed = false;
  String _gpuName = '';
  int _gpuLayers = 0;
  int _lastContextTokensUsed = 0;
  int _lastContextTokensTotal = 0;
  String? _resolvedBinaryPath;

  bool get isModelLoaded => _isLoaded && _process != null;
  bool get ggufVisionLoaded => _mmprojPath != null && _mmprojPath!.isNotEmpty;
  String get gpuName => _gpuName;
  int get gpuLayers => _gpuLayers;
  int get port => _port;
  String? get resolvedBinaryPath => _resolvedBinaryPath;

  static String get binaryName {
    if (Platform.isWindows) return 'llama-server.exe';
    return 'llama-server';
  }

  /// Returns the preferred directory to store or find local tools (`<workspace>/bin` or `<appSupport>/bin`).
  Future<String> getPreferredBinDir() async {
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

  /// Searches for `llama-server.exe` in:
  /// 1) Alongside executable: `p.join(p.dirname(Platform.resolvedExecutable), 'llama-server.exe')`
  /// 2) In project root / local tools: `p.join(Directory.current.path, 'bin', 'llama-server.exe')`
  /// 3) In application support tools directory
  /// 4) In system PATH (via `where.exe` or `which`)
  Future<String?> findServerBinary() async {
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

    // 3) In application support directory:
    try {
      final appSupportBin = await getPreferredBinDir();
      final c3 = p.join(appSupportBin, bin);
      if (await File(c3).exists()) {
        _resolvedBinaryPath = c3;
        return c3;
      }
    } catch (_) {}

    // 4) In system PATH:
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

    return null;
  }

  /// Checks if an existing server is running on a given port.
  Future<bool> probeServer(int targetPort) async {
    final client = http.Client();
    try {
      final uri = Uri.parse('http://127.0.0.1:$targetPort/health');
      final res = await client.get(uri).timeout(const Duration(milliseconds: 500));
      return res.statusCode == 200 || res.statusCode == 503;
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  /// Finds an available TCP port for `llama-server`.
  Future<int> findAvailablePort({int startPort = 50080}) async {
    for (int port = startPort; port < startPort + 50; port++) {
      try {
        final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
        await socket.close();
        return port;
      } catch (_) {}
    }
    return startPort;
  }

  /// Loads a model onto the Desktop llama-server engine.
  /// If cluster workers are active in `activeDesktopClusterEndpoints`, they will be passed
  /// via `--rpc worker1:port,worker2:port` to offload model layers over LAN!
  Future<DesktopLoadResult> loadModel({
    required String modelPath,
    required int contextSize,
    bool allowGpu = true,
    String? mmprojPath,
    List<String>? clusterEndpoints,
    void Function(double progress)? onProgress,
  }) async {
    _disposed = false;
    await unloadModel();

    final binary = await findServerBinary();
    if (binary == null) {
      // Check if user has an external server running (e.g. on 8080 or 50080)
      if (await probeServer(50080) || await probeServer(8080)) {
        _port = await probeServer(50080) ? 50080 : 8080;
        _isLoaded = true;
        _loadedModelPath = modelPath;
        _mmprojPath = mmprojPath;
        return DesktopLoadResult(
          success: true,
          message: 'Connected to existing llama-server at http://127.0.0.1:$_port',
          backend: 'external',
          runtime: 'llama',
        );
      }

      return DesktopLoadResult(
        success: false,
        message: 'llama-server executable not found.\n\n'
            'To run PC Master Mode:\n'
            '1. Place llama-server.exe in the bin/ directory, OR\n'
            '2. Download the official pre-built binaries from llama.cpp releases.',
      );
    }

    _port = await findAvailablePort(startPort: 50080);
    _loadedModelPath = modelPath;
    _mmprojPath = mmprojPath;
    _lastContextTokensTotal = contextSize;
    _lastContextTokensUsed = 0;

    // Detect threads: use processor count - 2 (clamped between 2 and 16)
    final threads = (Platform.numberOfProcessors - 2).clamp(2, 16);

    // Detect GPU & calculate offload layers
    _gpuLayers = 0;
    _gpuName = '';
    if (allowGpu) {
      if (Platform.isWindows) {
        _gpuName = 'DirectX / Vulkan GPU';
        _gpuLayers = 99; // Llama.cpp clamps to actual model layers
      } else if (Platform.isMacOS) {
        _gpuName = 'Apple Metal';
        _gpuLayers = 99;
      } else if (Platform.isLinux) {
        _gpuName = 'Vulkan / CUDA';
        _gpuLayers = 99;
      }
    }

    // Determine cluster RPC endpoints
    final effectiveEndpoints = clusterEndpoints ?? activeDesktopClusterEndpoints;

    final args = <String>[
      '-m', modelPath,
      '-c', '$contextSize',
      '-t', '$threads',
      '--port', '$_port',
      '--host', '127.0.0.1',
      if (_gpuLayers > 0) ...['-ngl', '$_gpuLayers'],
      if (effectiveEndpoints.isNotEmpty) ...['--rpc', effectiveEndpoints.join(',')],
      if (mmprojPath != null && mmprojPath.isNotEmpty) ...['--mmproj', mmprojPath],
    ];

    debugPrint('[DesktopEngine] Launching $binary with args: ${args.join(' ')}');
    onProgress?.call(0.1);

    final readyCompleter = Completer<bool>();
    final errorBuffer = StringBuffer();

    try {
      _process = await Process.start(
        binary,
        args,
        workingDirectory: p.dirname(binary),
        mode: ProcessStartMode.normal,
      );
    } catch (e) {
      return DesktopLoadResult(
        success: false,
        message: 'Failed to start llama-server process: $e',
      );
    }

    // Monitor stdout / stderr for load progress and readiness
    void handleOutput(String line) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) return;
      debugPrint('[llama-server] $trimmed');

      final lower = trimmed.toLowerCase();

      // Check for RPC connections
      if (lower.contains('rpc_client_connect') ||
          lower.contains('rpc client connected') ||
          lower.contains('connecting to rpc server')) {
        debugPrint('[DesktopEngine] ✓ RPC cluster worker connected!');
      }

      // Check for GPU offload info
      if (lower.contains('offloaded') && lower.contains('layers to gpu')) {
        final match = RegExp(r'offloaded\s+(\d+)/(\d+)\s+layers').firstMatch(lower);
        if (match != null) {
          _gpuLayers = int.tryParse(match.group(1)!) ?? _gpuLayers;
        }
      }

      // Check for readiness
      if (lower.contains('http server listening') ||
          lower.contains('server is listening') ||
          lower.contains('all slots are idle')) {
        if (!readyCompleter.isCompleted) {
          readyCompleter.complete(true);
        }
      }

      // Progress indicators
      if (lower.contains('loading model') || lower.contains('load_tensors')) {
        onProgress?.call(0.4);
      } else if (lower.contains('llama_init_from_model')) {
        onProgress?.call(0.8);
      }
    }

    _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(handleOutput);

    _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      errorBuffer.writeln(line);
      handleOutput(line);
    });

    _process!.exitCode.then((code) {
      debugPrint('[DesktopEngine] llama-server exited with code $code');
      _isLoaded = false;
      if (!readyCompleter.isCompleted) {
        readyCompleter.complete(false);
      }
    });

    // Poll /health endpoint while waiting for startup
    final healthPollTimer = Timer.periodic(const Duration(milliseconds: 300), (timer) async {
      if (readyCompleter.isCompleted) {
        timer.cancel();
        return;
      }
      try {
        final client = http.Client();
        final res = await client
            .get(Uri.parse('http://127.0.0.1:$_port/health'))
            .timeout(const Duration(milliseconds: 250));
        client.close();
        if (res.statusCode == 200) {
          timer.cancel();
          if (!readyCompleter.isCompleted) {
            readyCompleter.complete(true);
          }
        }
      } catch (_) {}
    });

    // Wait up to 90 seconds for large models / cluster loading
    bool success = false;
    try {
      success = await readyCompleter.future.timeout(const Duration(seconds: 90));
    } catch (_) {
      success = false;
    } finally {
      healthPollTimer.cancel();
    }

    if (!success || _process == null) {
      await unloadModel();
      final err = errorBuffer.toString().trim();
      return DesktopLoadResult(
        success: false,
        message: err.isNotEmpty
            ? 'Failed to load model on desktop engine:\n$err'
            : 'Timed out waiting for llama-server to initialize the model.',
      );
    }

    _isLoaded = true;
    onProgress?.call(1.0);

    final clusterNote = effectiveEndpoints.isNotEmpty
        ? ' across ${effectiveEndpoints.length} LAN worker(s) [${effectiveEndpoints.join(', ')}]'
        : '';
    final accel = _gpuLayers > 0
        ? 'GPU ($_gpuLayers layers, $_gpuName)'
        : 'CPU ($threads threads)';

    return DesktopLoadResult(
      success: true,
      message: 'Model loaded ($accel)$clusterNote.',
      gpuName: _gpuName,
      gpuLayers: _gpuLayers,
      runtime: 'llama',
      backend: _gpuLayers > 0 ? 'gpu' : 'cpu',
    );
  }

  /// Streams token generation from the desktop llama-server instance via OpenAI SSE protocol.
  Future<String> generate({
    required String prompt,
    List<Map<String, String>>? conversationHistory,
    required String systemPrompt,
    required int maxTokens,
    required double temperature,
    String? imagePath,
    void Function(String token)? onToken,
  }) async {
    if (!_isLoaded || _process == null) {
      throw StateError('Desktop model is not loaded');
    }

    final completer = Completer<String>();
    final buffer = StringBuffer();
    _activeClient = http.Client();

    final messages = <Map<String, dynamic>>[];
    if (systemPrompt.isNotEmpty) {
      messages.add({'role': 'system', 'content': systemPrompt});
    }

    if (conversationHistory != null) {
      for (final msg in conversationHistory) {
        final role = msg['role'] ?? 'user';
        final content = msg['content'] ?? '';
        if (content.isNotEmpty) {
          messages.add({'role': role, 'content': content});
        }
      }
    }

    if (imagePath != null && imagePath.isNotEmpty) {
      try {
        final imageFile = File(imagePath);
        if (await imageFile.exists()) {
          final bytes = await imageFile.readAsBytes();
          final b64 = base64Encode(bytes);
          final mime = imagePath.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg';
          messages.add({
            'role': 'user',
            'content': [
              {'type': 'text', 'text': prompt},
              {
                'type': 'image_url',
                'image_url': {'url': 'data:$mime;base64,$b64'},
              },
            ],
          });
        } else {
          messages.add({'role': 'user', 'content': prompt});
        }
      } catch (_) {
        messages.add({'role': 'user', 'content': prompt});
      }
    } else {
      messages.add({'role': 'user', 'content': prompt});
    }

    final requestBody = jsonEncode({
      'model': 'local',
      'messages': messages,
      'temperature': temperature,
      'max_tokens': maxTokens,
      'stream': true,
    });

    final request = http.Request(
      'POST',
      Uri.parse('http://127.0.0.1:$_port/v1/chat/completions'),
    )
      ..headers['Content-Type'] = 'application/json'
      ..headers['Accept'] = 'text/event-stream'
      ..body = requestBody;

    try {
      final response = await _activeClient!.send(request);
      if (response.statusCode != 200) {
        final errText = await response.stream.bytesToString();
        throw Exception('llama-server returned HTTP ${response.statusCode}: $errText');
      }

      response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
        (line) {
          final trimmed = line.trim();
          if (trimmed.isEmpty || !trimmed.startsWith('data:')) return;
          final jsonStr = trimmed.substring(5).trim();
          if (jsonStr == '[DONE]') {
            if (!completer.isCompleted) {
              completer.complete(buffer.toString());
            }
            return;
          }

          try {
            final data = jsonDecode(jsonStr) as Map<String, dynamic>;
            final choices = data['choices'] as List?;
            if (choices != null && choices.isNotEmpty) {
              final first = choices.first as Map<String, dynamic>;
              final delta = first['delta'] as Map<String, dynamic>?;
              final content = delta?['content'] as String?;
              if (content != null && content.isNotEmpty) {
                buffer.write(content);
                onToken?.call(content);
              }
            }
          } catch (_) {}
        },
        onDone: () {
          if (!completer.isCompleted) {
            completer.complete(buffer.toString());
          }
        },
        onError: (err) {
          if (!completer.isCompleted) {
            completer.completeError(err);
          }
        },
      );
    } catch (e) {
      if (!completer.isCompleted) {
        completer.completeError(e);
      }
    }

    return completer.future;
  }

  /// Cancels generation by interrupting the HTTP client and signaling slot cancellation to llama-server.
  Future<void> stop() async {
    _activeClient?.close();
    _activeClient = null;

    if (_isLoaded && _process != null) {
      try {
        final cancelClient = http.Client();
        await cancelClient
            .post(Uri.parse('http://127.0.0.1:$_port/slots/0?action=cancel'))
            .timeout(const Duration(milliseconds: 500));
        cancelClient.close();
      } catch (_) {}
    }
  }

  /// Returns context token usage if supported by the running server.
  Future<ContextInfo?> getContextInfo() async {
    if (!_isLoaded) return null;
    try {
      final client = http.Client();
      final res = await client
          .get(Uri.parse('http://127.0.0.1:$_port/slots'))
          .timeout(const Duration(milliseconds: 500));
      client.close();
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as List?;
        if (data != null && data.isNotEmpty) {
          final slot = data.first as Map<String, dynamic>;
          final nPast = slot['n_past'] as int? ?? 0;
          final nCtx = slot['n_ctx'] as int? ?? _lastContextTokensTotal;
          _lastContextTokensUsed = nPast;
          _lastContextTokensTotal = nCtx > 0 ? nCtx : _lastContextTokensTotal;
          final pct = _lastContextTokensTotal > 0
              ? (_lastContextTokensUsed / _lastContextTokensTotal) * 100
              : 0.0;
          return ContextInfo(
            tokensUsed: _lastContextTokensUsed,
            contextSize: _lastContextTokensTotal,
            usagePercentage: pct,
          );
        }
      }
    } catch (_) {}

    return ContextInfo(
      tokensUsed: _lastContextTokensUsed,
      contextSize: _lastContextTokensTotal > 0 ? _lastContextTokensTotal : 2048,
      usagePercentage: 0.0,
    );
  }

  /// Shuts down the llama-server subprocess and frees ports.
  Future<void> unloadModel() async {
    await stop();
    _isLoaded = false;
    _loadedModelPath = '';
    _mmprojPath = null;
    _gpuLayers = 0;
    _gpuName = '';

    if (_process != null) {
      try {
        _process!.kill(ProcessSignal.sigterm);
      } catch (_) {
        try {
          _process!.kill();
        } catch (_) {}
      }
      _process = null;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await unloadModel();
  }

  /// Downloads prebuilt `llama-server` and essential libraries from official llama.cpp releases.
  Future<bool> downloadAndInstallServer({
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
            // Prefer Vulkan or AVX2 x64 release
            if (name.contains('bin-win-vulkan-x64') && name.endsWith('.zip')) {
              downloadUrl = url;
              archiveName = name;
              break;
            } else if (name.contains('bin-win-avx2-x64') && name.endsWith('.zip')) {
              downloadUrl = url;
              archiveName = name;
            } else if (name.contains('bin-win') && name.contains('x64') && name.endsWith('.zip')) {
              downloadUrl ??= url;
              archiveName ??= name;
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

      if (downloadUrl == null) {
        debugPrint('[DesktopEngine] Could not find compatible llama.cpp binary asset.');
        return false;
      }

      onProgress?.call(0.15, 'Downloading ${archiveName ?? 'llama-server archive'}...');
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

      onProgress?.call(0.88, 'Extracting llama-server binaries...');
      final archive = ZipDecoder().decodeBytes(bytes);

      final binDir = await getPreferredBinDir();
      final dir = Directory(binDir);
      if (!await dir.exists()) await dir.create(recursive: true);

      final bin = binaryName;
      bool foundTarget = false;

      for (final file in archive) {
        if (!file.isFile) continue;
        final base = p.basename(file.name);

        final isTarget = base.toLowerCase() == bin.toLowerCase() ||
            base.toLowerCase() == 'rpc-server.exe' ||
            base.toLowerCase() == 'rpc-server' ||
            base.toLowerCase() == 'llama-cli.exe' ||
            base.toLowerCase() == 'llama-cli';

        final isLib = (Platform.isWindows && base.toLowerCase().endsWith('.dll')) ||
            (Platform.isLinux && base.contains('.so')) ||
            (Platform.isMacOS && base.contains('.dylib'));

        if (isTarget || isLib) {
          final outFile = File(p.join(dir.path, base));
          await outFile.writeAsBytes(file.content as List<int>);
          if (base.toLowerCase() == bin.toLowerCase()) {
            foundTarget = true;
            if (!Platform.isWindows) {
              await Process.run('chmod', ['+x', outFile.path]);
            }
            _resolvedBinaryPath = outFile.path;
          }
        }
      }

      if (foundTarget) {
        onProgress?.call(1.0, 'Installation complete!');
        return true;
      } else {
        throw Exception('Archive did not contain $bin');
      }
    } catch (e) {
      debugPrint('[DesktopEngine] Download failed: $e');
      return false;
    } finally {
      client.close();
    }
  }
}
