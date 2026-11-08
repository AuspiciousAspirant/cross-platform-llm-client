import 'dart:io' show Platform, Process;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../core/ui.dart';
import '../services/desktop_engine_manager.dart';

/// Clean, production-grade desktop engine setup assistant.
///
/// Features hardware GPU auto-detection (NVIDIA CUDA, AMD/Intel Vulkan, or AVX2 CPU),
/// binary installation status for both `llama-server` and `rpc-server`, and
/// single-click download & extraction directly from official llama.cpp releases.
class UnifiedEngineSetupCard extends StatefulWidget {
  final VoidCallback? onInstalled;
  final bool compact;

  const UnifiedEngineSetupCard({
    super.key,
    this.onInstalled,
    this.compact = false,
  });

  @override
  State<UnifiedEngineSetupCard> createState() => _UnifiedEngineSetupCardState();
}

class _UnifiedEngineSetupCardState extends State<UnifiedEngineSetupCard> {
  bool _isLoading = true;
  bool _isDownloading = false;
  double _progress = 0.0;
  String _statusMessage = '';
  String? _error;

  GpuDetectionResult? _gpuInfo;
  EngineBinaryStatus? _binaryStatus;
  EngineBackendFlavor _selectedFlavor = EngineBackendFlavor.vulkan;

  @override
  void initState() {
    super.initState();
    _loadState();
  }

  Future<void> _loadState() async {
    if (kIsWeb || (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS)) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    try {
      final gpu = await DesktopEngineManager.detectGpuHardware();
      final status = await DesktopEngineManager.checkBinaryStatus();
      if (mounted) {
        setState(() {
          _gpuInfo = gpu;
          _binaryStatus = status;
          _selectedFlavor = gpu.recommendedFlavor;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _startDownload() async {
    setState(() {
      _isDownloading = true;
      _error = null;
      _progress = 0.05;
      _statusMessage = 'Connecting to GitHub...';
    });

    try {
      final success = await DesktopEngineManager.downloadAndInstallEngine(
        flavor: _selectedFlavor,
        onProgress: (p, msg) {
          if (mounted) {
            setState(() {
              _progress = p;
              _statusMessage = msg;
            });
          }
        },
      );

      if (!mounted) return;

      if (success) {
        showToast(
          'Engine Installed Successfully',
          'llama-server and rpc-server are operational.',
          tone: ToastTone.success,
        );
        await _loadState();
        widget.onInstalled?.call();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Download failed: $e. You can manually place binaries in the bin/ folder.';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isDownloading = false);
      }
    }
  }

  Future<void> _openBinFolder() async {
    final status = _binaryStatus;
    if (status == null) return;
    try {
      if (Platform.isWindows) {
        await Process.run('explorer.exe', [status.binDirectory]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [status.binDirectory]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [status.binDirectory]);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb || (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS)) {
      return const SizedBox.shrink();
    }

    final t = AppTokens.of(context);

    if (_isLoading) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: t.hairline),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: t.accent),
            ),
            const SizedBox(width: 12),
            Text('Scanning engine binaries and GPU hardware...', style: t.caption),
          ],
        ),
      );
    }

    final gpu = _gpuInfo;
    final status = _binaryStatus;
    final isReady = status?.isFullyReady ?? false;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isReady ? t.hairline : t.accent.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header Row
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: isReady
                      ? t.green.withValues(alpha: 0.12)
                      : t.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.memory_rounded,
                  size: 20,
                  color: isReady ? t.green : t.accent,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text('Inference & RPC Engine', style: t.bodyStrong),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: isReady
                                ? t.green.withValues(alpha: 0.15)
                                : t.orange.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            isReady ? 'Ready' : 'Setup Needed',
                            style: t.micro.copyWith(
                              color: isReady ? t.green : t.orange,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      status?.summary ?? 'llama.cpp runtime binaries',
                      style: t.small,
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 14),

          // Hardware GPU Detection Pill
          if (gpu != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: t.fill,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: t.hairline),
              ),
              child: Row(
                children: [
                  Icon(Icons.bolt_rounded, size: 16, color: t.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Detected: ${gpu.gpuName} · Recommended: ${gpu.recommendedFlavor.shortName}',
                      style: t.caption.copyWith(fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],

          // Binary Status Badges
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: t.fill,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: (status?.hasMaster ?? false) ? t.hairline : t.orange.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        (status?.hasMaster ?? false)
                            ? Icons.check_circle_outline_rounded
                            : Icons.error_outline_rounded,
                        size: 14,
                        color: (status?.hasMaster ?? false) ? t.green : t.orange,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Master (llama-server)',
                          style: t.micro.copyWith(
                            color: (status?.hasMaster ?? false) ? t.text : t.orange,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: t.fill,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: (status?.hasWorker ?? false) ? t.hairline : t.orange.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        (status?.hasWorker ?? false)
                            ? Icons.check_circle_outline_rounded
                            : Icons.error_outline_rounded,
                        size: 14,
                        color: (status?.hasWorker ?? false) ? t.green : t.orange,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Worker (rpc-server)',
                          style: t.micro.copyWith(
                            color: (status?.hasWorker ?? false) ? t.text : t.orange,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // Download Progress UI
          if (_isDownloading) ...[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: t.fill,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: t.hairline),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: t.accent),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(_statusMessage, style: t.caption),
                      ),
                      Text('${(_progress * 100).toInt()}%', style: t.micro),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: _progress.clamp(0.0, 1.0),
                      backgroundColor: t.surface,
                      color: t.accent,
                      minHeight: 4,
                    ),
                  ),
                ],
              ),
            ),
          ] else ...[
            if (_error != null) ...[
              AppNotice(_error!, icon: Icons.warning_amber_rounded, color: t.orange),
              const SizedBox(height: 10),
            ],

            // Backend flavor selector on Windows/Linux
            if (!Platform.isMacOS) ...[
              DropdownButtonFormField<EngineBackendFlavor>(
                value: _selectedFlavor,
                decoration: InputDecoration(
                  labelText: 'Hardware Backend Acceleration',
                  labelStyle: t.micro.copyWith(color: t.muted),
                  filled: true,
                  fillColor: t.fill,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: t.hairline),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: t.hairline),
                  ),
                ),
                dropdownColor: t.surface,
                items: [
                  EngineBackendFlavor.vulkan,
                  EngineBackendFlavor.cuda12,
                  EngineBackendFlavor.cuda11,
                  EngineBackendFlavor.cpu,
                ].map((flavor) {
                  return DropdownMenuItem(
                    value: flavor,
                    child: Text(flavor.displayName, style: t.small),
                  );
                }).toList(),
                onChanged: (val) {
                  if (val != null) setState(() => _selectedFlavor = val);
                },
              ),
              const SizedBox(height: 12),
            ],

            // Actions Row
            Row(
              children: [
                Expanded(
                  child: PrimaryButton(
                    label: isReady ? 'Reinstall / Update Engine' : 'Download & Install Engine',
                    icon: Icons.download_rounded,
                    onPressed: _startDownload,
                  ),
                ),
                const SizedBox(width: 8),
                PillButton(
                  label: 'bin/',
                  icon: Icons.folder_open_rounded,
                  onPressed: _openBinFolder,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
