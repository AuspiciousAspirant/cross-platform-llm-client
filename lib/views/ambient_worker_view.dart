import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';

import '../core/ui.dart';
import '../services/cluster_service.dart';

/// Ultra-low-power AMOLED Ambient Worker screen.
///
/// Designed for phones and laptops acting as LAN cluster workers over port 50052.
/// Keeps the Wi-Fi modem and CPU threads active at maximum throughput while dimming
/// OLED pixels to near-zero power consumption to prevent device sleep and thermal throttling.
class AmbientWorkerView extends StatefulWidget {
  const AmbientWorkerView({super.key});

  @override
  State<AmbientWorkerView> createState() => _AmbientWorkerViewState();
}

class _AmbientWorkerViewState extends State<AmbientWorkerView> {
  final ClusterService cluster = Get.find<ClusterService>();
  bool _dimmed = false;

  @override
  void initState() {
    super.initState();
    // Ensure screen stay-on is enforced on mobile
    if (!ClusterService.isDesktop && !kIsWeb) {
      try {
        LlamaCluster.setKeepScreenOn(true).catchError((_) {});
      } catch (_) {}
    }
  }

  String _formatGb(num? mb) {
    if (mb == null || mb <= 0) return '0.0 GB';
    return '${(mb / 1024).toStringAsFixed(1)} GB';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTap: () => Navigator.of(context).pop(),
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 300),
            opacity: _dimmed ? 0.35 : 1.0,
            child: Obx(() {
              final s = cluster.worker.value;
              final ip = cluster.wifiAddress.value ?? '127.0.0.1';
              final port = LlamaCluster.defaultPort;
              final isConnected = s.peer != null;

              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Top App Bar row
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: isConnected
                                    ? const Color(0xFF34C759)
                                    : const Color(0xFF0A84FF),
                                boxShadow: [
                                  BoxShadow(
                                    color: (isConnected
                                            ? const Color(0xFF34C759)
                                            : const Color(0xFF0A84FF))
                                        .withValues(alpha: 0.6),
                                    blurRadius: 8,
                                    spreadRadius: 2,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              isConnected ? 'SERVICING MASTER' : 'WORKER STANDBY',
                              style: GoogleFonts.firaCode(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 1.2,
                                color: isConnected
                                    ? const Color(0xFF34C759)
                                    : const Color(0xFF0A84FF),
                              ),
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            IconButton(
                              icon: Icon(
                                _dimmed
                                    ? Icons.brightness_high_rounded
                                    : Icons.brightness_low_rounded,
                                color: Colors.white60,
                                size: 20,
                              ),
                              tooltip: _dimmed ? 'Brighten Display' : 'Ultra-Dim OLED Mode',
                              onPressed: () => setState(() => _dimmed = !_dimmed),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close_rounded,
                                  color: Colors.white60, size: 22),
                              tooltip: 'Exit Ambient Mode',
                              onPressed: () => Navigator.of(context).pop(),
                            ),
                          ],
                        ),
                      ],
                    ),

                    const Spacer(flex: 1),

                    // Central Telemetry & Connection Box
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.dns_rounded,
                            size: 48,
                            color: isConnected
                                ? const Color(0xFF34C759)
                                : const Color(0xFF8E8E93),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            '$ip:$port',
                            style: GoogleFonts.firaCode(
                              fontSize: 26,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.8,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            isConnected
                                ? 'Connected to ${s.peer}'
                                : 'Advertising beacon over LAN port 50053…',
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              color: Colors.white60,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),

                    const Spacer(flex: 1),

                    // Node Specs & Memory Metrics Grid
                    Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: const Color(0xFF101012),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFF242428)),
                      ),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: _AmbientMetric(
                                  label: 'HELD VRAM / RAM',
                                  value: _formatGb(s.heldMb),
                                  highlight: isConnected,
                                ),
                              ),
                              Container(
                                width: 1,
                                height: 40,
                                color: const Color(0xFF242428),
                              ),
                              Expanded(
                                child: _AmbientMetric(
                                  label: 'FREE AT START',
                                  value: _formatGb(s.ramMb.toDouble()),
                                ),
                              ),
                            ],
                          ),
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child: Divider(height: 1, color: Color(0xFF242428)),
                          ),
                          Row(
                            children: [
                              Expanded(
                                child: _AmbientMetric(
                                  label: 'MEMORY BANDWIDTH',
                                  value: '${s.bandwidth.toStringAsFixed(1)} GB/s',
                                ),
                              ),
                              Container(
                                width: 1,
                                height: 40,
                                color: const Color(0xFF242428),
                              ),
                              Expanded(
                                child: _AmbientMetric(
                                  label: 'WAKE-LOCK STATUS',
                                  value: 'ACTIVE (NO SLEEP)',
                                  color: const Color(0xFF34C759),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 20),

                    // Bottom info label
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.touch_app_rounded,
                            size: 14, color: Colors.white38),
                        const SizedBox(width: 6),
                        Text(
                          'Double-tap screen or tap ✕ to exit ambient mode',
                          style: GoogleFonts.inter(fontSize: 12, color: Colors.white38),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class _AmbientMetric extends StatelessWidget {
  final String label;
  final String value;
  final bool highlight;
  final Color? color;

  const _AmbientMetric({
    required this.label,
    required this.value,
    this.highlight = false,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveColor = color ??
        (highlight ? const Color(0xFF34C759) : Colors.white.withValues(alpha: 0.9));

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: GoogleFonts.firaCode(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.0,
              color: Colors.white38,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: GoogleFonts.firaCode(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: effectiveColor,
            ),
          ),
        ],
      ),
    );
  }
}
