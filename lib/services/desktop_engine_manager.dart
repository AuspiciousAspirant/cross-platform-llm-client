import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum GpuVendor { nvidia, amd, intel, apple, generic, cpu }

enum EngineBackendFlavor {
  vulkan,
  cuda12,
  cuda11,
  cpu,
  metal;

  String get displayName => switch (this) {
        EngineBackendFlavor.vulkan => 'Vulkan GPU (Universal · AMD / Intel / NVIDIA)',
        EngineBackendFlavor.cuda12 => 'NVIDIA CUDA 12 (Fastest for RTX 30xx / 40xx)',
        EngineBackendFlavor.cuda11 => 'NVIDIA CUDA 11 (Legacy NVIDIA GPUs)',
        EngineBackendFlavor.cpu => 'Universal CPU (AVX2 / Dynamic Dispatch)',
        EngineBackendFlavor.metal => 'Apple Metal (M1 / M2 / M3 / M4 / M5)',
      };

  String get shortName => switch (this) {
        EngineBackendFlavor.vulkan => 'Vulkan GPU',
        EngineBackendFlavor.cuda12 => 'CUDA 12',
        EngineBackendFlavor.cuda11 => 'CUDA 11',
        EngineBackendFlavor.cpu => 'CPU (AVX2)',
        EngineBackendFlavor.metal => 'Metal',
      };
}

class GpuDetectionResult {
  final GpuVendor vendor;
  final String gpuName;
  final bool hasVulkan;
  final bool hasNvidiaSmi;
  final EngineBackendFlavor recommendedFlavor;
  final String recommendationReason;

  const GpuDetectionResult({
    required this.vendor,
    required this.gpuName,
    required this.hasVulkan,
    required this.hasNvidiaSmi,
    required this.recommendedFlavor,
    required this.recommendationReason,
  });
}

class EngineBinaryStatus {
  final bool hasMaster;
  final bool hasWorker;
  final String? masterPath;
  final String? workerPath;
  final String binDirectory;

  const EngineBinaryStatus({
    required this.hasMaster,
    required this.hasWorker,
    this.masterPath,
    this.workerPath,
    required this.binDirectory,
  });

  bool get isFullyReady => hasMaster && hasWorker;

  String get summary {
    if (isFullyReady) return 'Master & RPC worker operational';
    if (hasMaster && !hasWorker) return 'Master ready (rpc-server missing)';
    if (!hasMaster && hasWorker) return 'RPC worker ready (llama-server missing)';
    return 'Engine binaries not installed';
  }
}

class DesktopEngineManager {
  static const String llamaCppLatestApiUrl =
      'https://api.github.com/repos/ggml-org/llama.cpp/releases/latest';
  static const String llamaCppFallbackApiUrl =
      'https://api.github.com/repos/ggerganov/llama.cpp/releases/latest';

  static String get masterBinaryName =>
      Platform.isWindows ? 'llama-server.exe' : 'llama-server';

  static List<String> get workerBinaryCandidates => Platform.isWindows
      ? const ['ggml-rpc-server.exe', 'rpc-server.exe', 'llama-rpc-server.exe']
      : const ['ggml-rpc-server', 'rpc-server', 'llama-rpc-server'];

  static String get workerBinaryName =>
      Platform.isWindows ? 'rpc-server.exe' : 'rpc-server';

  /// Resolves the preferred binary directory (<appSupport>/bin or <workspace>/bin).
  static Future<String> getPreferredBinDir() async {
    try {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      final distBin = Directory(p.join(exeDir, 'bin'));
      if (await distBin.exists()) {
        return distBin.path;
      }
    } catch (_) {}

    try {
      final appSupport = await getApplicationSupportDirectory();
      final appBin = Directory(p.join(appSupport.path, 'bin'));
      if (!await appBin.exists()) {
        await appBin.create(recursive: true);
      }
      return appBin.path;
    } catch (_) {
      final localBin = Directory(p.join(Directory.current.path, 'bin'));
      if (!localBin.existsSync()) {
        localBin.createSync(recursive: true);
      }
      return localBin.path;
    }
  }

  /// Verifies whether a binary has its required companion DLLs on Windows.
  static bool isCompleteBinary(String binaryPath) {
    if (!Platform.isWindows) return true;
    try {
      final f = File(binaryPath);
      final size = f.lengthSync();
      if (size < 500 * 1024) {
        final dir = p.dirname(binaryPath);
        final base = p.basename(binaryPath).toLowerCase();
        if (base.contains('llama-server')) {
          final implDll = File(p.join(dir, 'llama-server-impl.dll'));
          final llamaDll = File(p.join(dir, 'llama.dll'));
          if (!implDll.existsSync() && !llamaDll.existsSync()) {
            return false;
          }
        }
      }
      return true;
    } catch (_) {
      return true;
    }
  }

  /// Fast hardware GPU detection avoiding WMI/CIM sandboxed restrictions.
  static Future<GpuDetectionResult> detectGpuHardware() async {
    if (Platform.isMacOS) {
      return const GpuDetectionResult(
        vendor: GpuVendor.apple,
        gpuName: 'Apple Silicon (Metal)',
        hasVulkan: false,
        hasNvidiaSmi: false,
        recommendedFlavor: EngineBackendFlavor.metal,
        recommendationReason: 'Hardware-accelerated unified memory via Apple Metal.',
      );
    }

    if (Platform.isWindows) {
      final hasVulkan = File(r'C:\Windows\System32\vulkan-1.dll').existsSync();
      final hasNvidiaSmi = _checkWindowsNvidiaSmi();

      // Fast display adapter registry query via reg.exe (<20ms, 0 admin privileges needed)
      try {
        final regResult = await Process.run('reg', [
          'query',
          r'HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}',
          '/s',
          '/v',
          'DriverDesc',
        ]);

        if (regResult.exitCode == 0) {
          final stdout = regResult.stdout.toString();
          final lines = stdout.split(RegExp(r'\r?\n'));
          final gpus = <String>[];

          for (final line in lines) {
            if (line.contains('DriverDesc') && line.contains('REG_SZ')) {
              final parts = line.split('REG_SZ');
              if (parts.length > 1) {
                final name = parts[1].trim();
                if (name.isNotEmpty && !gpus.contains(name)) {
                  gpus.add(name);
                }
              }
            }
          }

          if (gpus.isNotEmpty) {
            final gpuSummary = gpus.join(', ');
            final lower = gpuSummary.toLowerCase();

            if (lower.contains('nvidia') ||
                lower.contains('geforce') ||
                lower.contains('quadro') ||
                lower.contains('rtx') ||
                lower.contains('gtx')) {
              return GpuDetectionResult(
                vendor: GpuVendor.nvidia,
                gpuName: gpuSummary,
                hasVulkan: hasVulkan,
                hasNvidiaSmi: hasNvidiaSmi,
                recommendedFlavor: EngineBackendFlavor.cuda12,
                recommendationReason:
                    'Dedicated NVIDIA Tensor Cores detected. CUDA 12 offers maximum throughput.',
              );
            } else if (lower.contains('amd') || lower.contains('radeon')) {
              return GpuDetectionResult(
                vendor: GpuVendor.amd,
                gpuName: gpuSummary,
                hasVulkan: hasVulkan,
                hasNvidiaSmi: hasNvidiaSmi,
                recommendedFlavor: EngineBackendFlavor.vulkan,
                recommendationReason:
                    'AMD Radeon graphics detected. Vulkan provides high-speed hardware offloading.',
              );
            } else if (lower.contains('intel') ||
                lower.contains('arc') ||
                lower.contains('iris')) {
              return GpuDetectionResult(
                vendor: GpuVendor.intel,
                gpuName: gpuSummary,
                hasVulkan: hasVulkan,
                hasNvidiaSmi: hasNvidiaSmi,
                recommendedFlavor: EngineBackendFlavor.vulkan,
                recommendationReason:
                    'Intel graphics detected. Vulkan provides hardware acceleration.',
              );
            }
          }
        }
      } catch (_) {}

      if (hasNvidiaSmi) {
        return GpuDetectionResult(
          vendor: GpuVendor.nvidia,
          gpuName: 'NVIDIA GPU (nvidia-smi)',
          hasVulkan: hasVulkan,
          hasNvidiaSmi: true,
          recommendedFlavor: EngineBackendFlavor.cuda12,
          recommendationReason: 'NVIDIA driver detected via nvidia-smi.',
        );
      }

      if (hasVulkan) {
        return const GpuDetectionResult(
          vendor: GpuVendor.generic,
          gpuName: 'Generic GPU (Vulkan Runtime)',
          hasVulkan: true,
          hasNvidiaSmi: false,
          recommendedFlavor: EngineBackendFlavor.vulkan,
          recommendationReason: 'Vulkan runtime library present on system.',
        );
      }

      return const GpuDetectionResult(
        vendor: GpuVendor.cpu,
        gpuName: 'CPU Only',
        hasVulkan: false,
        hasNvidiaSmi: false,
        recommendedFlavor: EngineBackendFlavor.cpu,
        recommendationReason: 'No discrete GPU detected. Dynamic AVX2 CPU dispatch.',
      );
    }

    // Linux detection
    if (Platform.isLinux) {
      bool hasNvidia = false;
      try {
        final p1 = Process.runSync('which', ['nvidia-smi']);
        if (p1.exitCode == 0) hasNvidia = true;
      } catch (_) {}

      if (hasNvidia) {
        return const GpuDetectionResult(
          vendor: GpuVendor.nvidia,
          gpuName: 'NVIDIA GPU (Linux)',
          hasVulkan: true,
          hasNvidiaSmi: true,
          recommendedFlavor: EngineBackendFlavor.cuda12,
          recommendationReason: 'NVIDIA GPU detected on Linux host.',
        );
      }

      return const GpuDetectionResult(
        vendor: GpuVendor.generic,
        gpuName: 'Linux Host',
        hasVulkan: true,
        hasNvidiaSmi: false,
        recommendedFlavor: EngineBackendFlavor.vulkan,
        recommendationReason: 'Standard Linux Vulkan / CPU architecture.',
      );
    }

    return const GpuDetectionResult(
      vendor: GpuVendor.cpu,
      gpuName: 'Universal Host',
      hasVulkan: false,
      hasNvidiaSmi: false,
      recommendedFlavor: EngineBackendFlavor.cpu,
      recommendationReason: 'Standard multi-threaded CPU execution.',
    );
  }

  static bool _checkWindowsNvidiaSmi() {
    return File(r'C:\Windows\System32\nvidia-smi.exe').existsSync() ||
        File(r'C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe').existsSync();
  }

  /// Scans known locations to check whether `llama-server` and `rpc-server` exist.
  static Future<EngineBinaryStatus> checkBinaryStatus() async {
    final binDir = await getPreferredBinDir();
    final masterBin = masterBinaryName;

    String? foundMaster;
    String? foundWorker;

    final candidateDirs = <String>[
      binDir,
      p.join(Directory.current.path, 'bin'),
      Directory.current.path,
    ];

    try {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      candidateDirs.add(exeDir);
      candidateDirs.add(p.join(exeDir, 'bin'));
    } catch (_) {}

    for (final dir in candidateDirs) {
      if (foundMaster == null) {
        final m = File(p.join(dir, masterBin));
        if (m.existsSync() && isCompleteBinary(m.path)) foundMaster = m.path;
      }
      if (foundWorker == null) {
        for (final wb in workerBinaryCandidates) {
          final w = File(p.join(dir, wb));
          if (w.existsSync() && isCompleteBinary(w.path)) {
            foundWorker = w.path;
            break;
          }
        }
      }
      if (foundMaster != null && foundWorker != null) break;
    }

    return EngineBinaryStatus(
      hasMaster: foundMaster != null,
      hasWorker: foundWorker != null,
      masterPath: foundMaster,
      workerPath: foundWorker,
      binDirectory: binDir,
    );
  }

  /// One-click automated engine downloader and installer.
  /// Downloads matching llama.cpp archive and installs both master & worker binaries.
  static Future<bool> downloadAndInstallEngine({
    EngineBackendFlavor? flavor,
    void Function(double progress, String status)? onProgress,
  }) async {
    final client = http.Client();
    try {
      onProgress?.call(0.05, 'Detecting optimal GPU architecture...');
      final detected = await detectGpuHardware();
      final targetFlavor = flavor ?? detected.recommendedFlavor;

      onProgress?.call(0.10, 'Querying latest llama.cpp release...');
      Map<String, dynamic>? releaseData;

      for (final apiUrl in [llamaCppLatestApiUrl, llamaCppFallbackApiUrl]) {
        try {
          final res = await client.get(Uri.parse(apiUrl), headers: {
            'User-Agent': 'PrivateLM-LLM-Client',
            'Accept': 'application/vnd.github.v3+json',
          }).timeout(const Duration(seconds: 10));

          if (res.statusCode == 200) {
            releaseData = jsonDecode(res.body) as Map<String, dynamic>;
            break;
          }
        } catch (_) {}
      }

      if (releaseData == null) {
        throw Exception('Unable to reach GitHub releases API for llama.cpp.');
      }

      final assets = (releaseData['assets'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      String? downloadUrl;
      String? archiveName;

      for (final asset in assets) {
        final name = (asset['name'] as String? ?? '').toLowerCase();
        final url = asset['browser_download_url'] as String?;
        if (url == null) continue;

        if (Platform.isWindows && name.endsWith('.zip')) {
          switch (targetFlavor) {
            case EngineBackendFlavor.cuda12:
              if (name.contains('bin-win-cuda-12') || name.contains('bin-win-cuda-cu12')) {
                downloadUrl = url;
                archiveName = name;
              }
              break;
            case EngineBackendFlavor.cuda11:
              if (name.contains('bin-win-cuda-11') || name.contains('bin-win-cuda-cu11')) {
                downloadUrl = url;
                archiveName = name;
              }
              break;
            case EngineBackendFlavor.vulkan:
              if (name.contains('bin-win-vulkan-x64')) {
                downloadUrl = url;
                archiveName = name;
              }
              break;
            case EngineBackendFlavor.cpu:
              if (name.contains('bin-win-cpu-x64') || name.contains('bin-win-avx2-x64')) {
                downloadUrl = url;
                archiveName = name;
              }
              break;
            default:
              break;
          }
        } else if (Platform.isMacOS) {
          if (name.contains('bin-macos-arm64') && (name.endsWith('.zip') || name.endsWith('.tar.gz'))) {
            downloadUrl = url;
            archiveName = name;
            break;
          }
        } else if (Platform.isLinux) {
          if (targetFlavor == EngineBackendFlavor.vulkan && name.contains('vulkan') && name.contains('ubuntu')) {
            downloadUrl = url;
            archiveName = name;
            break;
          } else if (name.contains('bin-ubuntu-x64')) {
            downloadUrl ??= url;
            archiveName ??= name;
          }
        }
      }

      // Fallback on Windows to Vulkan or CPU if specific CUDA asset wasn't found
      if (downloadUrl == null && Platform.isWindows) {
        for (final asset in assets) {
          final name = (asset['name'] as String? ?? '').toLowerCase();
          final url = asset['browser_download_url'] as String?;
          if (url == null || !name.endsWith('.zip')) continue;

          if (name.contains('bin-win-vulkan-x64')) {
            downloadUrl = url;
            archiveName = name;
            break;
          } else if (name.contains('bin-win') && name.contains('x64')) {
            downloadUrl ??= url;
            archiveName ??= name;
          }
        }
      }

      if (downloadUrl == null) {
        throw Exception('Could not locate compatible llama.cpp binary asset for $targetFlavor.');
      }

      onProgress?.call(0.18, 'Downloading ${archiveName ?? 'llama.cpp binaries'}...');
      final dlReq = http.Request('GET', Uri.parse(downloadUrl));
      final dlRes = await client.send(dlReq);

      if (dlRes.statusCode != 200) {
        throw Exception('Download failed with HTTP ${dlRes.statusCode}');
      }

      final totalBytes = dlRes.contentLength ?? 0;
      final bytes = <int>[];
      int received = 0;

      await for (final chunk in dlRes.stream) {
        bytes.addAll(chunk);
        received += chunk.length;
        if (totalBytes > 0) {
          final ratio = 0.18 + (received / totalBytes) * 0.67;
          final mb = (received / (1024 * 1024)).toStringAsFixed(1);
          final totalMb = (totalBytes / (1024 * 1024)).toStringAsFixed(1);
          onProgress?.call(ratio, 'Downloading: $mb / $totalMb MB');
        }
      }

      onProgress?.call(0.86, 'Extracting master & RPC worker binaries...');
      final archive = ZipDecoder().decodeBytes(bytes);

      final binDir = await getPreferredBinDir();
      final dir = Directory(binDir);
      if (!await dir.exists()) await dir.create(recursive: true);

      final masterBin = masterBinaryName.toLowerCase();
      final workerCandidatesLower =
          workerBinaryCandidates.map((c) => c.toLowerCase()).toSet();
      bool foundMaster = false;
      bool foundWorker = false;

      for (final file in archive) {
        if (!file.isFile) continue;
        final base = p.basename(file.name);
        final baseLower = base.toLowerCase();

        final isTarget = baseLower == masterBin ||
            workerCandidatesLower.contains(baseLower) ||
            baseLower == 'llama-cli.exe' ||
            baseLower == 'llama-cli';

        final isLib = (Platform.isWindows && baseLower.endsWith('.dll')) ||
            (Platform.isLinux && baseLower.contains('.so')) ||
            (Platform.isMacOS && baseLower.contains('.dylib'));

        if (isTarget || isLib) {
          final outFile = File(p.join(dir.path, base));
          await outFile.writeAsBytes(file.content as List<int>);

          if (baseLower == masterBin) {
            foundMaster = true;
            if (!Platform.isWindows) {
              await Process.run('chmod', ['+x', outFile.path]);
            }
          }
          if (workerCandidatesLower.contains(baseLower)) {
            foundWorker = true;
            if (!Platform.isWindows) {
              await Process.run('chmod', ['+x', outFile.path]);
            }
          }
        }
      }

      if (foundMaster || foundWorker) {
        onProgress?.call(1.0, 'Installation complete! Binaries ready in bin/');
        return true;
      } else {
        throw Exception('Archive did not contain $masterBin or RPC worker binary');
      }
    } catch (e) {
      debugPrint('[DesktopEngineManager] Download/install failed: $e');
      rethrow;
    } finally {
      client.close();
    }
  }

  /// Launches an external visible PowerShell terminal window executing the automated
  /// installation script so the user can observe download and extraction progress in CMD/PowerShell.
  static Future<bool> launchTerminalInstaller({String? targetDir}) async {
    if (!Platform.isWindows) return false;
    try {
      final bin = targetDir ?? await getPreferredBinDir();
      final candidateScripts = [
        p.join(Directory.current.path, 'scripts', 'download_desktop_binaries.ps1'),
        p.join(p.dirname(Platform.resolvedExecutable), 'scripts', 'download_desktop_binaries.ps1'),
        p.join(p.dirname(Platform.resolvedExecutable), 'download_desktop_binaries.ps1'),
      ];
      String? scriptPath;
      for (final s in candidateScripts) {
        if (File(s).existsSync()) {
          scriptPath = s;
          break;
        }
      }

      if (scriptPath != null) {
        await Process.start('powershell.exe', [
          '-NoExit',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          scriptPath,
          '-TargetDir',
          bin,
        ], runInShell: true);
        return true;
      }

      // Inline PowerShell command if script file is missing
      final psCmd = '''
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "  PrivateLM: Automated RPC Worker Installation      " -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan
\$bin = "$bin"
New-Item -ItemType Directory -Path \$bin -Force | Out-Null
Write-Host "Querying latest llama.cpp release..." -ForegroundColor Green
try {
    \$release = Invoke-RestMethod -Uri "https://api.github.com/repos/ggml-org/llama.cpp/releases/latest" -Headers @{"User-Agent"="PrivateLM"} -TimeoutSec 15
    \$asset = \$release.assets | Where-Object { \$_.name -like "*bin-win-vulkan-x64.zip" } | Select-Object -First 1
    if (-not \$asset) { \$asset = \$release.assets | Where-Object { \$_.name -like "*bin-win-avx2-x64.zip" } | Select-Object -First 1 }
    \$zip = Join-Path \$bin \$asset.name
    Write-Host "Downloading \$(\$asset.name)..." -ForegroundColor Green
    Invoke-WebRequest -Uri \$asset.browser_download_url -OutFile \$zip
    Write-Host "Extracting to \$bin..." -ForegroundColor Green
    Expand-Archive -Path \$zip -DestinationPath \$bin -Force
    Remove-Item \$zip -Force
    Write-Host "`nSUCCESS: RPC worker and companion DLLs installed into \$bin" -ForegroundColor Green
    Write-Host "You can close this window now." -ForegroundColor White
} catch {
    Write-Error "Failed to install automatically: \$_"
}
''';
      await Process.start('powershell.exe', [
        '-NoExit',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        psCmd,
      ], runInShell: true);
      return true;
    } catch (e) {
      debugPrint('[DesktopEngineManager] Failed to launch terminal installer: $e');
      return false;
    }
  }
}
