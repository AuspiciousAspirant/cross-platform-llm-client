import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:get/get.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/ui.dart';
import '../services/cluster_service.dart';
import '../services/desktop_rpc_worker.dart';

/// Phone cluster: pick Master (runs the model) or Worker (lends this phone),
/// and pair them by scanning the worker's QR code.
class ClusterView extends StatefulWidget {
  const ClusterView({super.key});

  @override
  State<ClusterView> createState() => _ClusterViewState();
}

class _ClusterViewState extends State<ClusterView> {
  final ClusterService cluster = Get.find<ClusterService>();
  Timer? _wifiTimer;
  ClusterDiagnosticsReport? _lastReport;
  bool _isRunningDiag = false;

  @override
  void initState() {
    super.initState();
    cluster.refreshWorkerStatus();
    cluster.refreshWifiAddress();
    if (cluster.role == ClusterRole.master) cluster.relocateWorkers();
    // Pick up Wi-Fi being turned on while this screen is open.
    _wifiTimer = Timer.periodic(
        const Duration(seconds: 3), (_) => cluster.refreshWifiAddress());
    _runDiagnostics();
  }

  Future<void> _runDiagnostics() async {
    if (_isRunningDiag) return;
    setState(() => _isRunningDiag = true);
    try {
      final report = await cluster.runDiagnostics();
      if (mounted) {
        setState(() {
          _lastReport = report;
          _isRunningDiag = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isRunningDiag = false);
    }
  }

  @override
  void dispose() {
    _wifiTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      appBar: appScreenBar(context,
          title: ClusterService.isDesktop
              ? 'Distributed LAN Cluster'
              : 'Phone cluster',
          showBack: true),
      body: Obx(() {
        final role = cluster.role;
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: ListView(
              padding: kPagePadding,
              children: [
                const SizedBox(height: 8),
                AppSegmented<ClusterRole>(
                  items: [
                    (ClusterRole.off, 'Off'),
                    if (ClusterService.canBeMaster) (ClusterRole.master, 'Master'),
                    (ClusterRole.worker, 'Worker'),
                  ],
                  selected: role,
                  onChanged: (newRole) async {
                    if (newRole == ClusterRole.worker && ClusterService.isDesktop) {
                      final bin = await cluster.desktopWorker.findRpcServerBinary();
                      if (bin == null && context.mounted) {
                        _showRpcServerSetupSheet(context);
                      }
                    }
                    await cluster.setRole(newRole);
                  },
                ),
                const SizedBox(height: 16),
                if (role != ClusterRole.off && cluster.wifiAddress.value == null) ...[
                  AppNotice(
                    'Turn on Wi-Fi or local network. All devices in the cluster must be on the same local network.',
                    icon: Icons.wifi_off_rounded,
                    color: t.orange,
                  ),
                  const SizedBox(height: 16),
                ],
                ...switch (role) {
                  ClusterRole.off => _offSection(),
                  ClusterRole.master => _masterSection(context),
                  ClusterRole.worker => _workerSection(context),
                },
                const SizedBox(height: 20),
                _buildDiagnosticsSection(context),
              ],
            ),
          ),
        );
      }),
    );
  }

  List<Widget> _offSection() => [
        AppNotice(
          ClusterService.canBeMaster
              ? 'Run models too big for one phone by sharing the work across '
                  'phones on the same Wi-Fi.\n\n'
                  'Master: the phone you chat on. It runs the model.\n'
                  'Worker: a phone that lends its memory to the master.'
              : 'Help an Android phone running PrivateLM run models too big for '
                  'it alone: choose Worker, then scan this device\'s QR code '
                  'from that phone.',
          icon: Icons.hub_outlined,
        ),
      ];

  // ── Worker ─────────────────────────────────────────────────────────────

  List<Widget> _workerSection(BuildContext context) {
    final t = AppTokens.of(context);
    final s = cluster.worker.value;
    final qr = cluster.workerQrData;

    final Widget body;
    if (s.state == 'error') {
      final isBinaryMissing = ClusterService.isDesktop &&
          (s.error?.contains('rpc-server') == true ||
              s.error?.contains('not found') == true);
      body = isBinaryMissing
          ? _desktopMissingBinaryCard(context)
          : _centered(context, [
              Icon(Icons.error_outline_rounded, size: 40, color: t.red),
              const SizedBox(height: 12),
              Text('Worker stopped', style: t.bodyStrong),
              const SizedBox(height: 4),
              Text(s.error ?? 'Unknown error',
                  style: t.caption, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              PillButton(
                  label: 'Try again',
                  primary: true,
                  onPressed: () async {
                    if (ClusterService.isDesktop) {
                      final bin = await cluster.desktopWorker.findRpcServerBinary();
                      if (bin == null && context.mounted) {
                        _showRpcServerSetupSheet(context);
                        return;
                      }
                    }
                    cluster.startWorker();
                  }),
            ]);
    } else if (s.peer != null) {
      body = _centered(context, [
        _PulsingDot(color: t.green),
        const SizedBox(height: 14),
        Text('Sharing with master', style: t.bodyStrong.copyWith(fontSize: 18)),
        const SizedBox(height: 4),
        Text(s.peer!, style: t.caption),
        const SizedBox(height: 20),
        Row(children: [
          Expanded(child: _Stat(label: 'Holding', value: _gb(s.heldMb))),
          Expanded(child: _Stat(label: 'Free at start', value: _gb(s.ramMb))),
          Expanded(child: _Stat(label: 'Memory speed', value: '${s.bandwidth.toStringAsFixed(1)} GB/s')),
        ]),
      ]);
    } else if (!s.running || qr == null) {
      body = _centered(context, [
        const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5)),
        const SizedBox(height: 16),
        Text(
          s.running
              ? 'Waiting for network…'
              : (ClusterService.isDesktop
                  ? 'Starting RPC worker…'
                  : 'Measuring this phone…'),
          style: t.caption,
        ),
      ]);
    } else {
      body = _centered(context, [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          child: QrImageView(data: qr, size: 220, padding: EdgeInsets.zero),
        ),
        const SizedBox(height: 16),
        Text('Scan this from the master device', style: t.bodyStrong),
        const SizedBox(height: 6),
        Row(mainAxisSize: MainAxisSize.min, children: [
          StatusDot(t.green, size: 8),
          const SizedBox(width: 6),
          Text(
            'Ready · ${cluster.wifiAddress.value ?? "Local network"}',
            style: t.caption,
          ),
        ]),
        if (cluster.wifiAddress.value != null) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: t.cardBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: t.divider),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lan_rounded, size: 16, color: t.accent),
                const SizedBox(width: 8),
                SelectableText(
                  '${cluster.wifiAddress.value}:${LlamaCluster.defaultPort}',
                  style: t.bodyStrong.copyWith(
                    fontFamily: 'monospace',
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  icon: const Icon(Icons.copy_rounded, size: 16),
                  tooltip: 'Copy IP and Port',
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    Clipboard.setData(ClipboardData(
                      text:
                          '${cluster.wifiAddress.value}:${LlamaCluster.defaultPort}',
                    ));
                    showToast('Copied',
                        '${cluster.wifiAddress.value}:${LlamaCluster.defaultPort}');
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'On your master device, scan the QR code or tap "Enter IP" to connect.',
            style: t.small,
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: _Stat(label: 'Free memory', value: _gb(s.ramMb))),
          Expanded(
            child: _Stat(
              label: 'Memory speed',
              value: '${s.bandwidth.toStringAsFixed(1)} GB/s',
            ),
          ),
        ]),
      ]);
    }

    return [
      if (s.throttled) ...[
        AppNotice(
          'Android is slowing this worker down (slow cores only), which slows '
          'the whole cluster. Set PrivateLM\'s battery use to Unrestricted, '
          'then turn Worker off and on.',
          icon: Icons.speed_rounded,
          color: t.orange,
        ),
        const SizedBox(height: 8),
        const Align(
          alignment: Alignment.centerLeft,
          child: PillButton(
            label: 'Set Unrestricted',
            primary: true,
            onPressed: LlamaCluster.requestBatteryUnrestricted,
          ),
        ),
        const SizedBox(height: 16),
      ],
      AppCard(padding: const EdgeInsets.fromLTRB(16, 24, 16, 20), child: body),
      SectionFootnote(ClusterService.workerStopsWithApp
          ? 'Keep this device plugged in, on the same Wi-Fi, with PrivateLM open: '
              'iOS pauses apps in the background. Close PrivateLM to stop sharing.'
          : ClusterService.isDesktop
              ? 'Keep PrivateLM open on the same local network: rpc-server '
                  'lends this PC\'s CPU and memory to master devices on your LAN. '
                  'Set Phone cluster to Off to stop.'
              : 'Keep this phone plugged in and on the same Wi-Fi, with PrivateLM '
                  'open: the screen stays on while sharing, because Android slows '
                  'background work. Set Phone cluster to Off to stop.'),
    ];
  }

  Widget _centered(BuildContext context, List<Widget> children) =>
      Column(crossAxisAlignment: CrossAxisAlignment.center, children: children);

  // ── Master ─────────────────────────────────────────────────────────────

  List<Widget> _masterSection(BuildContext context) {
    final t = AppTokens.of(context);
    final isWide = MediaQuery.sizeOf(context).width >= 560;

    return [
      if (cluster.split.length > 1) ...[
        _SplitCard(shares: cluster.split),
        const SizedBox(height: 16),
      ],
      PrimaryButton(
        label: ClusterService.isDesktop
            ? 'Add worker by IP'
            : 'Scan a worker\'s QR code',
        icon: ClusterService.isDesktop
            ? Icons.add_link_rounded
            : Icons.qr_code_scanner_rounded,
        onPressed: () => _scanQr(context),
      ),
      SectionHeader('Active cluster workers (${cluster.workers.length})'),
      if (cluster.workers.isEmpty)
        const AppGroup(children: [
          EmptyState(
            icon: Icons.devices_other_rounded,
            title: 'No workers connected yet',
            message: 'On each other phone or PC, open Phone cluster, choose Worker, '
                'or tap "+ Add" on any discovered worker below.',
          ),
        ])
      else
        AppGroup(dividerIndent: 60, children: [
          for (final w in cluster.workers)
            AppRow(
              icon: _workerDeviceIcon(w),
              title: w.model ?? w.name,
              subtitle: [
                w.endpoint,
                _deviceType(w),
                if (w.ramMb != null) '${_gb(w.ramMb!)} free',
                if (w.bandwidth != null) '${w.bandwidth!.toStringAsFixed(1)} GB/s',
              ].join(' · '),
              trailing: IconButton(
                icon: Icon(Icons.close_rounded, color: t.muted),
                tooltip: 'Remove',
                onPressed: () => cluster.remove(w),
              ),
            ),
        ]),
      const SectionFootnote(
        'Used the next time you load a GGUF model. If the model fits on this '
        'phone you can keep it here, which is faster. If it doesn\'t, the '
        'fastest phones get the biggest share and phones that aren\'t needed '
        'are left out.',
      ),
      const SizedBox(height: 8),
      SectionHeader('Nearby LAN workers (${cluster.found.length})'),
      Row(children: [
        PillButton(
          label: cluster.isScanning.value ? 'Scanning LAN…' : 'Scan LAN',
          icon: cluster.isScanning.value ? Icons.sync_rounded : Icons.radar_rounded,
          primary: !cluster.isScanning.value,
          onPressed: cluster.isScanning.value ? null : cluster.scanNearby,
        ),
        const SizedBox(width: 10),
        PillButton(
          label: 'Enter IP',
          icon: Icons.keyboard_rounded,
          onPressed: () => _enterIp(context),
        ),
        if (cluster.isScanning.value) ...[
          const SizedBox(width: 12),
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ],
      ]),
      if (cluster.isScanning.value) ...[
        const SizedBox(height: 10),
        const AppProgressBar(height: 3),
      ],
      const SizedBox(height: 12),
      if (cluster.found.isNotEmpty)
        AppGroup(dividerIndent: 60, children: [
          for (final w in cluster.found)
            AppRow(
              icon: _workerDeviceIcon(w),
              title: w.model ?? w.name,
              subtitle: [
                w.endpoint,
                _deviceType(w),
                if (!isWide && w.ramMb != null) '${_gb(w.ramMb!)} RAM',
                if (!isWide && w.bandwidth != null) '${w.bandwidth!.toStringAsFixed(1)} GB/s',
              ].join(' · '),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isWide && w.ramMb != null) ...[
                    AppTag(
                      '${_gb(w.ramMb!)} RAM',
                      icon: Icons.memory_rounded,
                    ),
                    const SizedBox(width: 6),
                  ],
                  if (isWide && w.bandwidth != null) ...[
                    AppTag(
                      '${w.bandwidth!.toStringAsFixed(1)} GB/s',
                      icon: Icons.speed_rounded,
                      color: t.green,
                    ),
                    const SizedBox(width: 8),
                  ],
                  PillButton(
                    label: '+ Add',
                    primary: true,
                    icon: Icons.add_rounded,
                    onPressed: () => _report(cluster.addFound(w)),
                  ),
                ],
              ),
            ),
        ])
      else if (cluster.isScanning.value)
        const AppGroup(children: [
          AppRow(
            icon: Icons.radar_rounded,
            title: 'Searching for LAN workers…',
            subtitle: 'Listening on UDP port 50053 for zero-config announcements',
          ),
        ])
      else
        const AppGroup(children: [
          AppRow(
            icon: Icons.wifi_find_rounded,
            title: 'No nearby workers detected',
            subtitle: 'Start Worker mode on any device on this LAN, or tap Scan LAN',
          ),
        ]),
      const SectionFootnote(
        'PrivateLM workers announce their CPU, RAM, and memory bandwidth over UDP port 50053. '
        'Discovered devices can be added to your cluster with one click.',
      ),
    ];
  }

  IconData _workerDeviceIcon(ClusterWorker w) {
    final name = '${w.model ?? ''} ${w.name}'.toLowerCase();
    if (name.contains('win') || name.contains('pc') || name.contains('desktop')) {
      return Icons.desktop_windows_rounded;
    }
    if (name.contains('mac') || name.contains('darwin') || name.contains('apple')) {
      return Icons.laptop_mac_rounded;
    }
    if (name.contains('linux') || name.contains('ubuntu')) {
      return Icons.terminal_rounded;
    }
    return Icons.smartphone_rounded;
  }

  String _deviceType(ClusterWorker w) {
    final name = '${w.model ?? ''} ${w.name}'.toLowerCase();
    if (name.contains('win') || name.contains('pc') || name.contains('desktop')) {
      return 'Windows PC';
    }
    if (name.contains('mac') || name.contains('darwin') || name.contains('apple')) {
      return 'macOS';
    }
    if (name.contains('linux') || name.contains('ubuntu')) {
      return 'Linux';
    }
    if (name.contains('pixel') || name.contains('galaxy') || name.contains('android')) {
      return 'Android';
    }
    return 'LAN Worker';
  }

  Future<void> _scanQr(BuildContext context) async {
    if (ClusterService.isDesktop) {
      await _enterIp(context);
      return;
    }
    final code = await Get.to<String>(() => const _QrScanPage());
    if (code != null) await _report(cluster.addFromQr(code));
  }

  Future<void> _enterIp(BuildContext context) async {
    final ctrl = TextEditingController();
    final input = await showAppSheet<String>(
      context,
      title: 'Enter worker IP',
      subtitle: 'Shown under the worker\'s QR code',
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: appInputDecoration(ctx,
                hint: '192.168.1.20:${LlamaCluster.defaultPort}'),
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
          const SizedBox(height: 16),
          PrimaryButton(label: 'Add', onPressed: () => Navigator.pop(ctx, ctrl.text)),
        ],
      ),
    );
    ctrl.dispose();
    if (input != null) await _report(cluster.addManual(input));
  }

  Widget _desktopMissingBinaryCard(BuildContext context) {
    final t = AppTokens.of(context);
    return _centered(context, [
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: t.accent.withValues(alpha: 0.12),
          shape: BoxShape.circle,
        ),
        child: Icon(Icons.dns_rounded, size: 36, color: t.accent),
      ),
      const SizedBox(height: 14),
      Text('llama.cpp RPC Server Required',
          style: t.bodyStrong.copyWith(fontSize: 17)),
      const SizedBox(height: 6),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          'To act as a worker, this PC needs the official llama.cpp ${DesktopRpcWorker.binaryName} binary in the bin folder.',
          style: t.caption,
          textAlign: TextAlign.center,
        ),
      ),
      const SizedBox(height: 18),
      Wrap(
        spacing: 10,
        runSpacing: 10,
        alignment: WrapAlignment.center,
        children: [
          PillButton(
            label: 'Install RPC Server',
            icon: Icons.download_rounded,
            primary: true,
            onPressed: () => _showRpcServerSetupSheet(context),
          ),
          PillButton(
            label: 'GitHub Releases',
            icon: Icons.open_in_new_rounded,
            onPressed: DesktopRpcWorker.openReleasesPage,
          ),
          PillButton(
            label: 'Check again',
            onPressed: () => cluster.startWorker(),
          ),
        ],
      ),
    ]);
  }

  Widget _buildDiagnosticsSection(BuildContext context) {
    final t = AppTokens.of(context);
    final report = _lastReport;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('LAN Diagnostics & Benchmark'),
        AppCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.monitor_heart_outlined, color: t.accent, size: 20),
                  const SizedBox(width: 8),
                  Text('Cluster Readiness', style: t.bodyStrong),
                  const Spacer(),
                  if (_isRunningDiag)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    PillButton(
                      label: report == null ? 'Run Self-Test' : 'Re-test',
                      icon: Icons.play_arrow_rounded,
                      onPressed: _runDiagnostics,
                    ),
                ],
              ),
              const SizedBox(height: 12),
              if (report == null)
                Text(
                  'Verify port 50052 availability, test memory bandwidth, and validate LAN adapters.',
                  style: t.caption,
                )
              else ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: (report.isReady ? t.green : t.orange).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: (report.isReady ? t.green : t.orange).withValues(alpha: 0.25),
                    ),
                  ),
                  child: Row(
                    children: [
                      StatusDot(report.isReady ? t.green : t.orange, size: 8),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          report.statusSummary,
                          style: t.small.copyWith(
                            color: report.isReady ? t.green : t.orange,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: _Stat(
                        label: 'LAN IP',
                        value: report.lanIp ?? 'Not on LAN',
                      ),
                    ),
                    Expanded(
                      child: _Stat(
                        label: 'Port 50052',
                        value: report.isWorkerRunning
                            ? 'Listening'
                            : (report.isPort50052Available ? 'Available' : 'Blocked'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _Stat(
                        label: 'Memory Speed',
                        value: '${report.memoryBandwidthGbps.toStringAsFixed(1)} GB/s',
                      ),
                    ),
                    Expanded(
                      child: _Stat(
                        label: 'Free RAM',
                        value: _gb(report.freeRamMb.toDouble()),
                      ),
                    ),
                  ],
                ),
                if (ClusterService.isDesktop) ...[
                  const SizedBox(height: 12),
                  const Divider(height: 1),
                  const SizedBox(height: 10),
                  Text('Local Tooling Binaries', style: t.small.copyWith(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(
                        report.hasWorkerBinary ? Icons.check_circle_rounded : Icons.cancel_rounded,
                        size: 16,
                        color: report.hasWorkerBinary ? t.green : t.red,
                      ),
                      const SizedBox(width: 6),
                      Text('rpc-server (Worker): ', style: t.caption),
                      Text(
                        report.hasWorkerBinary ? 'Ready' : 'Missing',
                        style: t.caption.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const Spacer(),
                      Icon(
                        report.hasMasterBinary ? Icons.check_circle_rounded : Icons.cancel_rounded,
                        size: 16,
                        color: report.hasMasterBinary ? t.green : t.red,
                      ),
                      const SizedBox(width: 6),
                      Text('llama-server (Master): ', style: t.caption),
                      Text(
                        report.hasMasterBinary ? 'Ready' : 'Missing',
                        style: t.caption.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }

  void _showRpcServerSetupSheet(BuildContext context) {
    showAppSheet(
      context,
      title: 'PC Worker Setup',
      builder: (ctx) => _RpcServerSetupSheet(cluster: cluster),
    );
  }

  Future<void> _report(Future<String?> adding) async {
    final error = await adding;
    if (error != null) {
      showToast('Couldn\'t add worker', error, tone: ToastTone.error);
    } else {
      showToast('Worker added', 'Used the next time you load a GGUF model.',
          tone: ToastTone.success);
    }
  }
}

class _RpcServerSetupSheet extends StatefulWidget {
  final ClusterService cluster;
  const _RpcServerSetupSheet({required this.cluster});

  @override
  State<_RpcServerSetupSheet> createState() => _RpcServerSetupSheetState();
}

class _RpcServerSetupSheetState extends State<_RpcServerSetupSheet> {
  bool _isDownloading = false;
  double _progress = 0.0;
  String _statusMessage = '';
  String? _error;
  String _binDir = '';

  @override
  void initState() {
    super.initState();
    DesktopRpcWorker.getPreferredBinDir().then((dir) {
      if (mounted) setState(() => _binDir = dir);
    });
  }

  Future<void> _startDownload() async {
    setState(() {
      _isDownloading = true;
      _error = null;
      _progress = 0.05;
      _statusMessage = 'Connecting to GitHub...';
    });

    final success = await widget.cluster.desktopWorker.downloadAndInstallRpcServer(
      onProgress: (p, status) {
        if (mounted) {
          setState(() {
            _progress = p;
            _statusMessage = status;
          });
        }
      },
    );

    if (!mounted) return;

    if (success) {
      showToast('RPC Server Installed', 'Starting worker service...',
          tone: ToastTone.success);
      Navigator.of(context).pop();
      await widget.cluster.startWorker();
    } else {
      setState(() {
        _isDownloading = false;
        _error =
            'Automatic download could not complete. You can manually download the release zip from GitHub and extract ${DesktopRpcWorker.binaryName} into the bin folder.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: t.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.dns_rounded, size: 24, color: t.accent),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('llama.cpp RPC Server',
                        style: t.bodyStrong.copyWith(fontSize: 17)),
                    const SizedBox(height: 2),
                    Text(
                        'Turn this PC into a high-performance compute node for your cluster.',
                        style: t.caption),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          if (_isDownloading) ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: t.cardBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: t.divider),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(_statusMessage, style: t.bodyStrong),
                      ),
                      Text('${(_progress * 100).toInt()}%', style: t.caption),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: _progress.clamp(0.0, 1.0),
                      backgroundColor: t.fill,
                      color: t.accent,
                      minHeight: 6,
                    ),
                  ),
                ],
              ),
            ),
          ] else ...[
            if (_error != null) ...[
              AppNotice(_error!,
                  icon: Icons.warning_amber_rounded, color: t.orange),
              const SizedBox(height: 14),
            ],
            PrimaryButton(
              label: 'One-Click Download & Install',
              icon: Icons.download_rounded,
              onPressed: _startDownload,
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: t.cardBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: t.divider),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Manual Installation', style: t.bodyStrong),
                  const SizedBox(height: 6),
                  Text(
                    'Download llama.cpp release zip from GitHub, extract ${DesktopRpcWorker.binaryName} (and runtime DLLs) into:',
                    style: t.caption,
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: t.fill,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SelectableText(
                      _binDir.isNotEmpty
                          ? _binDir
                          : 'bin/${DesktopRpcWorker.binaryName}',
                      style: t.small.copyWith(fontFamily: 'monospace'),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      PillButton(
                        label: 'Open bin folder',
                        icon: Icons.folder_open_rounded,
                        onPressed: () {
                          if (_binDir.isNotEmpty) {
                            DesktopRpcWorker.openFolder(_binDir);
                          }
                        },
                      ),
                      PillButton(
                        label: 'GitHub Releases',
                        icon: Icons.open_in_new_rounded,
                        onPressed: DesktopRpcWorker.openReleasesPage,
                      ),
                      PillButton(
                        label: 'Check again',
                        primary: true,
                        onPressed: () async {
                          final bin = await widget.cluster.desktopWorker
                              .findRpcServerBinary();
                          if (bin != null) {
                            if (context.mounted) Navigator.of(context).pop();
                            await widget.cluster.startWorker();
                          } else {
                            showToast('Not Found',
                                'Could not find ${DesktopRpcWorker.binaryName} yet.',
                                tone: ToastTone.error);
                          }
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

String _gb(num mb) => '${(mb / 1024).toStringAsFixed(1)} GB';

/// How the loaded model is spread across phones: a stacked bar and legend.
class _SplitCard extends StatelessWidget {
  final List<ClusterShare> shares;
  const _SplitCard({required this.shares});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final cluster = Get.find<ClusterService>();
    final colors = [t.accent, t.green, t.orange, const Color(0xFFAF52DE), t.red];
    final total = shares.fold<double>(0, (a, s) => a + s.mb);

    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Distributed model topology', style: t.bodyStrong),
            Obx(() {
              final ms = cluster.clusterLatencyMs.value;
              if (ms > 0) {
                return AppTag('${ms}ms avg', icon: Icons.speed_rounded, color: t.green);
              }
              return const SizedBox.shrink();
            }),
          ],
        ),
        const SizedBox(height: 2),
        Text('Running on ${shares.length} devices · ${_gb(total)}', style: t.caption),
        const SizedBox(height: 14),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: 12,
            child: Row(children: [
              for (var i = 0; i < shares.length; i++)
                Expanded(
                  flex: (shares[i].mb / total * 1000).round().clamp(1, 1000),
                  child: Container(
                    margin: EdgeInsets.only(right: i == shares.length - 1 ? 0 : 2),
                    color: shares[i].isHealthy ? colors[i % colors.length] : t.red,
                  ),
                ),
            ]),
          ),
        ),
        const SizedBox(height: 14),
        for (var i = 0; i < shares.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              StatusDot(shares[i].isHealthy ? colors[i % colors.length] : t.red, size: 10),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            shares[i].isThisPhone
                                ? '${shares[i].name} (this device)'
                                : shares[i].name,
                            style: t.body,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (!shares[i].isHealthy) ...[
                          const SizedBox(width: 6),
                          AppTag('Offline', color: t.red),
                        ],
                      ],
                    ),
                    Text(
                      [
                        'Layers ${shares[i].startLayer}–${shares[i].endLayer}',
                        if (!shares[i].isThisPhone && shares[i].pingMs != null)
                          '${shares[i].pingMs}ms',
                      ].join(' · '),
                      style: t.caption,
                    ),
                  ],
                ),
              ),
              Text('${(shares[i].mb / total * 100).round()}%', style: t.bodyStrong),
              const SizedBox(width: 10),
              SizedBox(
                width: 58,
                child: Text(_gb(shares[i].mb), textAlign: TextAlign.right, style: t.caption),
              ),
            ]),
          ),
        Obx(() {
          final dropped = cluster.droppedWorkers;
          if (dropped.isEmpty) return const SizedBox.shrink();
          return Container(
            margin: const EdgeInsets.only(top: 10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: t.red.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: t.red.withValues(alpha: 0.25), width: 0.5),
            ),
            child: Row(
              children: [
                Icon(Icons.warning_amber_rounded, size: 20, color: t.red),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Worker unreachable',
                          style: t.bodyStrong.copyWith(color: t.red, fontSize: 13.5)),
                      const SizedBox(height: 1),
                      Text('${dropped.join(', ')} failed health checks',
                          style: t.caption.copyWith(color: t.red)),
                    ],
                  ),
                ),
                PillButton(
                  label: 'Local Fallback',
                  destructive: true,
                  onPressed: () => cluster.fallbackToLocal(),
                ),
              ],
            ),
          );
        }),
      ]),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  const _Stat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Column(children: [
      Text(value, style: t.bodyStrong),
      const SizedBox(height: 2),
      Text(label, style: t.small, textAlign: TextAlign.center),
    ]);
  }
}

/// Live indicator for an active connection.
class _PulsingDot extends StatefulWidget {
  final Color color;
  const _PulsingDot({required this.color});

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))
        ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 56,
      height: 56,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) => Stack(alignment: Alignment.center, children: [
          Container(
            width: 24 + 32 * _c.value,
            height: 24 + 32 * _c.value,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.color.withValues(alpha: 0.35 * (1 - _c.value)),
            ),
          ),
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(shape: BoxShape.circle, color: widget.color),
            child: const Icon(Icons.hub_rounded, size: 14, color: Colors.white),
          ),
        ]),
      ),
    );
  }
}

/// Full-screen camera that returns the first QR code it reads.
class _QrScanPage extends StatefulWidget {
  const _QrScanPage();

  @override
  State<_QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<_QrScanPage> {
  MobileScannerController? _controller;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    if (kIsWeb || !ClusterService.isDesktop) {
      _controller =
          MobileScannerController(formats: const [BarcodeFormat.qrCode]);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    final value = capture.barcodes
        .map((b) => b.rawValue ?? '')
        .firstWhere((v) => v.isNotEmpty, orElse: () => '');
    if (value.isEmpty) return;
    _done = true;
    Get.back(result: value);
  }

  @override
  Widget build(BuildContext context) {
    if (ClusterService.isDesktop) {
      return Scaffold(
        appBar: AppBar(title: const Text('Scan worker QR code')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'QR code scanning is not supported on desktop. Please enter worker IP manually.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16),
            ),
          ),
        ),
      );
    }
    final controller = _controller;
    if (controller == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Scan worker QR code'),
      ),
      body: Stack(children: [
        MobileScanner(controller: controller, onDetect: _onDetect),
        Center(
          child: Container(
            width: 240,
            height: 240,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white, width: 2),
              borderRadius: BorderRadius.circular(20),
            ),
          ),
        ),
        const Positioned(
          left: 24,
          right: 24,
          bottom: 48,
          child: Text(
            'Point at the QR code on the worker phone',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white, fontSize: 15),
          ),
        ),
      ]),
    );
  }
}
