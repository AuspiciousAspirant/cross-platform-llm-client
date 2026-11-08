import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';

import '../controllers/server_controller.dart';
import '../core/haptics.dart';
import '../core/ui.dart';
import '../services/openai_server_service.dart';

/// Shows the Developer Integration Drawer & Client Presets sheet.
///
/// Provides copy-ready configurations for Cursor, Open WebUI, Obsidian,
/// Continue.dev, and cURL / Python scripts.
Future<void> showOpenAiClientPresetsSheet(BuildContext context) {
  final t = AppTokens.of(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: t.isDark ? const Color(0xFF141416) : Colors.white,
    barrierColor: Colors.black.withValues(alpha: t.isDark ? 0.65 : 0.38),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    constraints: const BoxConstraints(maxWidth: 820),
    builder: (ctx) => const OpenAiClientPresetsSheet(),
  );
}

enum _HostTarget { localhost, lan }

/// Developer Integration Drawer & Client Presets for PrivateLM's
/// built-in OpenAI-compatible API gateway.
class OpenAiClientPresetsSheet extends StatefulWidget {
  const OpenAiClientPresetsSheet({super.key});

  @override
  State<OpenAiClientPresetsSheet> createState() =>
      _OpenAiClientPresetsSheetState();
}

class _OpenAiClientPresetsSheetState extends State<OpenAiClientPresetsSheet> {
  int _selectedToolIndex = 0;
  _HostTarget _hostTarget = _HostTarget.localhost;
  String? _lanIp;
  bool _hideApiKey = true;

  final List<String> _tools = const [
    'Cursor',
    'Continue.dev',
    'Open WebUI',
    'Obsidian',
    'cURL / CLI',
    'Python SDK',
  ];

  @override
  void initState() {
    super.initState();
    _resolveLanIp();
  }

  Future<void> _resolveLanIp() async {
    final ip = await OpenAiServerService.getReachableIpv4Address();
    if (mounted && ip != null) {
      setState(() {
        _lanIp = ip;
      });
    }
  }

  ServerController? get _serverCtrl {
    return Get.isRegistered<ServerController>()
        ? Get.find<ServerController>()
        : null;
  }

  OpenAiServerService? get _serverService {
    if (Get.isRegistered<OpenAiServerService>()) {
      return Get.find<OpenAiServerService>();
    }
    return _serverCtrl?.server;
  }

  String _resolveHost() {
    if (_hostTarget == _HostTarget.lan) {
      if (_lanIp != null && _lanIp!.isNotEmpty) return _lanIp!;
      final sHost = _serverService?.host;
      if (sHost != null && sHost.isNotEmpty) return sHost;
      return '192.168.1.x';
    }
    return '127.0.0.1';
  }

  int _resolvePort() {
    return _serverService?.port ?? ServerController.port;
  }

  String _resolveApiKey() {
    final keyFromService = _serverService?.apiKey;
    if (keyFromService != null && keyFromService.trim().isNotEmpty) {
      return keyFromService.trim();
    }
    final keyFromCtrl = _serverCtrl?.effectiveApiKey;
    if (keyFromCtrl != null && keyFromCtrl.trim().isNotEmpty) {
      return keyFromCtrl.trim();
    }
    final rawKey = _serverCtrl?.apiKey.value.trim();
    if (rawKey != null && rawKey.isNotEmpty) {
      return rawKey;
    }
    return 'sk-privatelm';
  }

  String _resolveModelName() {
    final ctrl = _serverCtrl;
    if (ctrl != null && ctrl.hasLocalModel) {
      final name = ctrl.inference.loadedModelName.value.trim();
      if (name.isNotEmpty) return name;
    }
    return 'local';
  }

  bool _isServerRunning() {
    return _serverService?.isRunning ?? (_serverCtrl?.isRunning.value ?? false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final ctrl = _serverCtrl;
    if (ctrl == null) {
      return _buildContent(context, t, null);
    }
    return Obx(() => _buildContent(context, t, ctrl));
  }

  Widget _buildContent(
      BuildContext context, AppTokens t, ServerController? ctrl) {
    final isRunning = ctrl?.isRunning.value ?? _isServerRunning();
    final host = _resolveHost();
    final port = _resolvePort();
    final apiKey = _resolveApiKey();
    final modelName = _resolveModelName();
    final baseUrl = 'http://$host:$port';
    final v1Url = '$baseUrl/v1';
    final hasRealKey = ctrl?.requiresApiKey == true && apiKey != 'sk-privatelm';

    return Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.90,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Grab Handle
            Center(
              child: Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 8),
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: t.outline,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),

            // Sheet Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 12, 10),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: t.accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: t.accent.withValues(alpha: 0.25),
                        width: 0.5,
                      ),
                    ),
                    child: Icon(Icons.hub_outlined, color: t.accent, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Developer Client Presets',
                          style: GoogleFonts.inter(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.4,
                            color: t.text,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Ready-to-copy configurations for external AI tools',
                          style: t.caption,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.close_rounded, size: 20, color: t.muted),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),

            // Live Gateway Status Bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: _LiveGatewayBanner(
                isRunning: isRunning,
                v1Url: v1Url,
                modelName: modelName,
                hasKey: hasRealKey,
                onStartServer: ctrl != null && !isRunning
                    ? () {
                        Haptics.mediumImpact();
                        ctrl.startServer();
                      }
                    : null,
              ),
            ),

            const SizedBox(height: 12),

            // Target Network Selector (Localhost vs LAN IP)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: _TargetNetworkSelector(
                selectedTarget: _hostTarget,
                lanIp: _lanIp,
                onTargetChanged: (target) {
                  Haptics.selectionClick();
                  setState(() => _hostTarget = target);
                },
              ),
            ),

            const SizedBox(height: 12),

            // Tool Tab Segment Selector
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: List.generate(_tools.length, (idx) {
                  final tool = _tools[idx];
                  final isSelected = _selectedToolIndex == idx;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _ToolPillTab(
                      label: tool,
                      icon: _iconForTool(idx),
                      isSelected: isSelected,
                      onTap: () {
                        Haptics.selectionClick();
                        setState(() => _selectedToolIndex = idx);
                      },
                    ),
                  );
                }),
              ),
            ),

            const SizedBox(height: 12),
            Divider(height: 1, thickness: 0.5, color: t.hairline),

            // Tool Content Body
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 32),
                child: _buildToolPresetContent(
                  toolIndex: _selectedToolIndex,
                  host: host,
                  port: port,
                  apiKey: apiKey,
                  modelName: modelName,
                  baseUrl: baseUrl,
                  v1Url: v1Url,
                  hideApiKey: _hideApiKey,
                  onToggleHideApiKey: () {
                    Haptics.lightImpact();
                    setState(() => _hideApiKey = !_hideApiKey);
                  },
                ),
              ),
            ),
          ],
        ),
      );
  }

  IconData _iconForTool(int idx) {
    return switch (idx) {
      0 => Icons.code_rounded, // Cursor
      1 => Icons.fast_forward_rounded, // Continue.dev
      2 => Icons.web_rounded, // Open WebUI
      3 => Icons.edit_note_rounded, // Obsidian
      4 => Icons.terminal_rounded, // cURL / CLI
      5 => Icons.data_object_rounded, // Python
      _ => Icons.api_rounded,
    };
  }

  Widget _buildToolPresetContent({
    required int toolIndex,
    required String host,
    required int port,
    required String apiKey,
    required String modelName,
    required String baseUrl,
    required String v1Url,
    required bool hideApiKey,
    required VoidCallback onToggleHideApiKey,
  }) {
    return switch (toolIndex) {
      0 => _CursorPreset(
          v1Url: v1Url,
          apiKey: apiKey,
          modelName: modelName,
          hideApiKey: hideApiKey,
          onToggleHideApiKey: onToggleHideApiKey,
        ),
      1 => _ContinueDevPreset(
          v1Url: v1Url,
          apiKey: apiKey,
          modelName: modelName,
        ),
      2 => _OpenWebUiPreset(
          v1Url: v1Url,
          apiKey: apiKey,
          modelName: modelName,
          host: host,
          port: port,
        ),
      3 => _ObsidianPreset(
          v1Url: v1Url,
          apiKey: apiKey,
          modelName: modelName,
        ),
      4 => _CurlCliPreset(
          v1Url: v1Url,
          baseUrl: baseUrl,
          apiKey: apiKey,
          modelName: modelName,
        ),
      5 => _PythonSdkPreset(
          v1Url: v1Url,
          apiKey: apiKey,
          modelName: modelName,
        ),
      _ => const SizedBox.shrink(),
    };
  }
}

// ── Live Gateway Status Bar ─────────────────────────────────────────────────

class _LiveGatewayBanner extends StatelessWidget {
  final bool isRunning;
  final String v1Url;
  final String modelName;
  final bool hasKey;
  final VoidCallback? onStartServer;

  const _LiveGatewayBanner({
    required this.isRunning,
    required this.v1Url,
    required this.modelName,
    required this.hasKey,
    this.onStartServer,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.hairline, width: 0.5),
      ),
      child: Row(
        children: [
          StatusDot(isRunning ? t.green : t.orange, size: 8),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(
                      isRunning ? 'Gateway Online' : 'Gateway Stopped',
                      style: t.bodyStrong.copyWith(fontSize: 13),
                    ),
                    const SizedBox(width: 8),
                    AppTag(
                      hasKey ? 'Auth Key Active' : 'Auth Open',
                      color: hasKey ? t.accent : t.muted,
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  isRunning
                      ? 'Serving $modelName at $v1Url'
                      : 'Presets show projected endpoints for $modelName',
                  style: t.mono.copyWith(fontSize: 11.5, color: t.muted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (!isRunning && onStartServer != null)
            PillButton(
              label: 'Start Gateway',
              icon: Icons.play_arrow_rounded,
              onPressed: onStartServer,
            ),
        ],
      ),
    );
  }
}

// ── Target Network Selector ─────────────────────────────────────────────────

class _TargetNetworkSelector extends StatelessWidget {
  final _HostTarget selectedTarget;
  final String? lanIp;
  final ValueChanged<_HostTarget> onTargetChanged;

  const _TargetNetworkSelector({
    required this.selectedTarget,
    required this.lanIp,
    required this.onTargetChanged,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: t.fill,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.hairline, width: 0.5),
      ),
      child: Row(
        children: [
          Expanded(
            child: _HostOptionPill(
              title: 'Localhost',
              subtitle: '127.0.0.1 (This PC / Device)',
              icon: Icons.computer_rounded,
              isSelected: selectedTarget == _HostTarget.localhost,
              onTap: () => onTargetChanged(_HostTarget.localhost),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: _HostOptionPill(
              title: 'LAN IP',
              subtitle: lanIp != null ? lanIp! : 'Network IP (Cross-Device)',
              icon: Icons.wifi_rounded,
              isSelected: selectedTarget == _HostTarget.lan,
              onTap: () => onTargetChanged(_HostTarget.lan),
            ),
          ),
        ],
      ),
    );
  }
}

class _HostOptionPill extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  const _HostOptionPill({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(9),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: isSelected ? t.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
          border: isSelected
              ? Border.all(color: t.outline, width: 0.5)
              : Border.all(color: Colors.transparent, width: 0.5),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: t.isDark ? 0.3 : 0.05),
                    blurRadius: 4,
                    offset: const Offset(0, 1),
                  ),
                ]
              : null,
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 16,
              color: isSelected ? t.accent : t.muted,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: t.bodyStrong.copyWith(
                      fontSize: 12.5,
                      color: isSelected ? t.text : t.muted,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: t.mono.copyWith(
                      fontSize: 11,
                      color: isSelected ? t.text : t.faint,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Tool Pill Tab ───────────────────────────────────────────────────────────

class _ToolPillTab extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  const _ToolPillTab({
    required this.label,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? (t.isDark ? Colors.white.withValues(alpha: 0.12) : t.surfacePressed)
              : t.fill,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? t.outline : t.hairline,
            width: 0.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 15,
              color: isSelected ? t.accent : t.muted,
            ),
            const SizedBox(width: 7),
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                color: isSelected ? t.text : t.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Preset 1: Cursor ────────────────────────────────────────────────────────

class _CursorPreset extends StatelessWidget {
  final String v1Url;
  final String apiKey;
  final String modelName;
  final bool hideApiKey;
  final VoidCallback onToggleHideApiKey;

  const _CursorPreset({
    required this.v1Url,
    required this.apiKey,
    required this.modelName,
    required this.hideApiKey,
    required this.onToggleHideApiKey,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);

    final allConfig = '''
# Cursor OpenAI Settings Override
Base URL: $v1Url
API Key: $apiKey
Model: $modelName
'''.trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _PresetIntro(
          title: 'Cursor Integration',
          description:
              'Connect Cursor to PrivateLM as an OpenAI-compatible provider. '
              'Run AI code edits and completions locally without telemetry or cloud round-trips.',
          badge: 'Editor / IDE',
        ),
        const SizedBox(height: 16),

        // Config Rows
        AppGroup(
          children: [
            _PresetValueRow(
              label: 'Base URL',
              value: v1Url,
              tooltip: 'Copy Base URL',
            ),
            _PresetValueRow(
              label: 'API Key',
              value: apiKey,
              isSecret: true,
              obscure: hideApiKey,
              onToggleObscure: onToggleHideApiKey,
              tooltip: 'Copy API Key',
            ),
            _PresetValueRow(
              label: 'Model Identifier',
              value: modelName,
              tooltip: 'Copy Model Name',
            ),
          ],
        ),

        const SizedBox(height: 12),

        // 1-Click All Config Copy
        _CopyAllBar(
          label: 'Copy Complete Cursor Settings',
          content: allConfig,
          toastSubtitle: 'Cursor Base URL, API Key & Model copied.',
        ),

        const SizedBox(height: 16),
        const SectionHeader('How to set up in Cursor'),
        AppGroup(
          children: const [
            _StepRow(
              stepNumber: 1,
              instruction: 'Open Cursor Settings (Cmd+, or Ctrl+,) → Features → Models.',
            ),
            _StepRow(
              stepNumber: 2,
              instruction: 'Enable "OpenAI API Key" and turn ON "Override OpenAI Base URL".',
            ),
            _StepRow(
              stepNumber: 3,
              instruction: 'Paste the Base URL and API Key from above.',
            ),
            _StepRow(
              stepNumber: 4,
              instruction: 'Add a new model named "local" or your active model identifier.',
            ),
          ],
        ),
      ],
    );
  }
}

// ── Preset 2: Continue.dev ──────────────────────────────────────────────────

class _ContinueDevPreset extends StatelessWidget {
  final String v1Url;
  final String apiKey;
  final String modelName;

  const _ContinueDevPreset({
    required this.v1Url,
    required this.apiKey,
    required this.modelName,
  });

  @override
  Widget build(BuildContext context) {
    final configJsonSnippet = '''
{
  "models": [
    {
      "title": "PrivateLM ($modelName)",
      "provider": "openai",
      "model": "$modelName",
      "apiBase": "$v1Url",
      "apiKey": "$apiKey"
    }
  ],
  "tabAutocompleteModel": {
    "title": "PrivateLM Autocomplete",
    "provider": "openai",
    "model": "$modelName",
    "apiBase": "$v1Url",
    "apiKey": "$apiKey"
  }
}'''.trim();

    final modelOnlySnippet = '''
{
  "title": "PrivateLM ($modelName)",
  "provider": "openai",
  "model": "$modelName",
  "apiBase": "$v1Url",
  "apiKey": "$apiKey"
}'''.trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _PresetIntro(
          title: 'Continue.dev (VS Code & JetBrains)',
          description:
              'Open-source AI coding copilot. Paste this models block directly '
              'into your ~/.continue/config.json file.',
          badge: 'VS Code Extension',
        ),
        const SizedBox(height: 16),

        _CodeSnippetCard(
          title: 'config.json Snippet (Chat & Autocomplete)',
          lang: 'json',
          code: configJsonSnippet,
        ),

        const SizedBox(height: 12),

        Row(
          children: [
            Expanded(
              child: _CopyAllBar(
                label: 'Copy Model Object Only',
                content: modelOnlySnippet,
                toastSubtitle: 'Continue.dev model block copied.',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _CopyAllBar(
                label: 'Copy apiBase URL',
                content: v1Url,
                toastSubtitle: 'apiBase URL copied.',
              ),
            ),
          ],
        ),

        const SizedBox(height: 16),
        const SectionHeader('How to set up in Continue.dev'),
        AppGroup(
          children: const [
            _StepRow(
              stepNumber: 1,
              instruction: 'Click the gear icon in the Continue sidebar in VS Code / JetBrains.',
            ),
            _StepRow(
              stepNumber: 2,
              instruction: 'Select "Open config.json" (or edit ~/.continue/config.json).',
            ),
            _StepRow(
              stepNumber: 3,
              instruction: 'Paste the snippet into the "models" array and save the file.',
            ),
          ],
        ),
      ],
    );
  }
}

// ── Preset 3: Open WebUI ────────────────────────────────────────────────────

class _OpenWebUiPreset extends StatelessWidget {
  final String v1Url;
  final String apiKey;
  final String modelName;
  final String host;
  final int port;

  const _OpenWebUiPreset({
    required this.v1Url,
    required this.apiKey,
    required this.modelName,
    required this.host,
    required this.port,
  });

  @override
  Widget build(BuildContext context) {
    // Note: When running Open WebUI in Docker on the SAME machine,
    // host.docker.internal should be referenced if host is 127.0.0.1.
    final dockerUrl = host == '127.0.0.1' || host == 'localhost'
        ? 'http://host.docker.internal:$port/v1'
        : v1Url;

    final envSnippet = '''
OPENAI_API_BASE_URL="$v1Url"
OPENAI_API_KEY="$apiKey"
'''.trim();

    final dockerRunSnippet = '''
docker run -d -p 3000:8080 \\
  -e OPENAI_API_BASE_URL="$dockerUrl" \\
  -e OPENAI_API_KEY="$apiKey" \\
  -v open-webui:/app/backend/data \\
  --name open-webui \\
  --restart always \\
  ghcr.io/open-webui/open-webui:main
'''.trim();

    final dockerComposeSnippet = '''
services:
  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    ports:
      - "3000:8080"
    environment:
      - OPENAI_API_BASE_URL=$dockerUrl
      - OPENAI_API_KEY=$apiKey
    volumes:
      - open-webui:/app/backend/data
    restart: unless-stopped

volumes:
  open-webui:
'''.trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _PresetIntro(
          title: 'Open WebUI Integration',
          description:
              'Connect Open WebUI container or native server to PrivateLM as an external '
              'OpenAI provider for rich multi-user web chat, document RAG, and arena modes.',
          badge: 'Self-Hosted Web UI',
        ),
        const SizedBox(height: 16),

        AppGroup(
          children: [
            _PresetValueRow(
              label: 'OPENAI_API_BASE_URL',
              value: v1Url,
              tooltip: 'Copy Base URL',
            ),
            _PresetValueRow(
              label: 'OPENAI_API_KEY',
              value: apiKey,
              tooltip: 'Copy API Key',
            ),
          ],
        ),

        const SizedBox(height: 14),

        _CodeSnippetCard(
          title: 'Environment Variables (.env)',
          lang: 'bash',
          code: envSnippet,
        ),

        const SizedBox(height: 12),

        _CodeSnippetCard(
          title: 'Docker Run Command (Instant Launch)',
          lang: 'bash',
          code: dockerRunSnippet,
        ),

        const SizedBox(height: 12),

        _CodeSnippetCard(
          title: 'Docker Compose Snippet',
          lang: 'yaml',
          code: dockerComposeSnippet,
        ),
      ],
    );
  }
}

// ── Preset 4: Obsidian ──────────────────────────────────────────────────────

class _ObsidianPreset extends StatelessWidget {
  final String v1Url;
  final String apiKey;
  final String modelName;

  const _ObsidianPreset({
    required this.v1Url,
    required this.apiKey,
    required this.modelName,
  });

  @override
  Widget build(BuildContext context) {
    final customHeadersJson = '''
{
  "Authorization": "Bearer $apiKey",
  "Content-Type": "application/json"
}'''.trim();

    final textGenEndpoint = '$v1Url/chat/completions';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _PresetIntro(
          title: 'Obsidian Plugins',
          description:
              'Empower your second brain with local intelligence. Configure '
              'Text Generator and Smart Connections plugins.',
          badge: 'PKM & Notes',
        ),
        const SizedBox(height: 16),

        const SectionHeader('Text Generator Plugin Settings'),
        AppGroup(
          children: [
            _PresetValueRow(
              label: 'Provider',
              value: 'Custom / OpenAI',
              tooltip: 'Copy Provider',
            ),
            _PresetValueRow(
              label: 'Endpoint',
              value: textGenEndpoint,
              tooltip: 'Copy TextGen Endpoint',
            ),
            _PresetValueRow(
              label: 'API Key',
              value: apiKey,
              tooltip: 'Copy API Key',
            ),
            _PresetValueRow(
              label: 'Model Identifier',
              value: modelName,
              tooltip: 'Copy Model',
            ),
          ],
        ),

        const SizedBox(height: 16),

        const SectionHeader('Smart Connections Plugin Settings'),
        AppGroup(
          children: [
            _PresetValueRow(
              label: 'Custom Base URL',
              value: v1Url,
              tooltip: 'Copy Base URL',
            ),
            _PresetValueRow(
              label: 'API Key',
              value: apiKey,
              tooltip: 'Copy API Key',
            ),
            _PresetValueRow(
              label: 'Model',
              value: modelName,
              tooltip: 'Copy Model',
            ),
          ],
        ),

        const SizedBox(height: 14),

        _CodeSnippetCard(
          title: 'Custom Headers JSON',
          lang: 'json',
          code: customHeadersJson,
        ),
      ],
    );
  }
}

// ── Preset 5: cURL & CLI ────────────────────────────────────────────────────

class _CurlCliPreset extends StatelessWidget {
  final String v1Url;
  final String baseUrl;
  final String apiKey;
  final String modelName;

  const _CurlCliPreset({
    required this.v1Url,
    required this.baseUrl,
    required this.apiKey,
    required this.modelName,
  });

  @override
  Widget build(BuildContext context) {
    final chatCompletionCurl =
        'curl -X POST $v1Url/chat/completions \\\n'
        '  -H "Content-Type: application/json" \\\n'
        '  -H "Authorization: Bearer $apiKey" \\\n'
        '  -d \'{"model":"$modelName","messages":[{"role":"user","content":"Hello from terminal!"}]}\'';

    final streamingCurl =
        'curl -N -X POST $v1Url/chat/completions \\\n'
        '  -H "Content-Type: application/json" \\\n'
        '  -H "Authorization: Bearer $apiKey" \\\n'
        '  -d \'{"model":"$modelName","messages":[{"role":"user","content":"Count to 5."}],"stream":true}\'';

    final modelsCurl =
        'curl $v1Url/models \\\n'
        '  -H "Authorization: Bearer $apiKey"';

    final healthCurl = 'curl $baseUrl/health';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _PresetIntro(
          title: 'cURL & Terminal Snippets',
          description:
              'Fast 1-liner commands to verify server connectivity, query loaded models, '
              'and test chat streaming directly from bash, zsh, or powershell.',
          badge: 'CLI / Shell',
        ),
        const SizedBox(height: 16),

        _CodeSnippetCard(
          title: '1-Liner: Chat Completion',
          lang: 'bash',
          code: chatCompletionCurl,
        ),

        const SizedBox(height: 12),

        _CodeSnippetCard(
          title: '1-Liner: Streaming Chat Completion (-N)',
          lang: 'bash',
          code: streamingCurl,
        ),

        const SizedBox(height: 12),

        _CodeSnippetCard(
          title: '1-Liner: List Models (/v1/models)',
          lang: 'bash',
          code: modelsCurl,
        ),

        const SizedBox(height: 12),

        _CodeSnippetCard(
          title: '1-Liner: Health Check (/health)',
          lang: 'bash',
          code: healthCurl,
        ),
      ],
    );
  }
}

// ── Preset 6: Python SDK ────────────────────────────────────────────────────

class _PythonSdkPreset extends StatelessWidget {
  final String v1Url;
  final String apiKey;
  final String modelName;

  const _PythonSdkPreset({
    required this.v1Url,
    required this.apiKey,
    required this.modelName,
  });

  @override
  Widget build(BuildContext context) {
    final pythonOneLiner =
        'python -c "from openai import OpenAI; client = OpenAI(base_url=\'$v1Url\', api_key=\'$apiKey\'); print(client.chat.completions.create(model=\'$modelName\', messages=[{\'role\':\'user\',\'content\':\'Hello!\'}]).choices[0].message.content)"';

    final pythonScript = '''
from openai import OpenAI

# Initialize client pointing to PrivateLM gateway
client = OpenAI(
    base_url="$v1Url",
    api_key="$apiKey",
)

# Stream completion tokens in real-time
response = client.chat.completions.create(
    model="$modelName",
    messages=[
        {"role": "system", "content": "You are a concise AI assistant."},
        {"role": "user", "content": "Explain quantum computing in one sentence."},
    ],
    stream=True,
)

for chunk in response:
    content = chunk.choices[0].delta.content or ""
    print(content, end="", flush=True)
print()
'''.trim();

    final langChainSnippet = '''
from langchain_openai import ChatOpenAI

llm = ChatOpenAI(
    base_url="$v1Url",
    api_key="$apiKey",
    model="$modelName",
    temperature=0.7,
)

print(llm.invoke("What are three benefits of local LLMs?").content)
'''.trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _PresetIntro(
          title: 'Python (openai >= 1.0.0 & LangChain)',
          description:
              'Official OpenAI Python client library and LangChain integration. '
              'Drop-in replacement for OpenAI endpoints with 100% parameter compatibility.',
          badge: 'Python SDK',
        ),
        const SizedBox(height: 16),

        _CodeSnippetCard(
          title: 'Python CLI 1-Liner Test',
          lang: 'bash',
          code: pythonOneLiner,
        ),

        const SizedBox(height: 12),

        _CodeSnippetCard(
          title: 'Python Streaming Script (OpenAI SDK)',
          lang: 'python',
          code: pythonScript,
        ),

        const SizedBox(height: 12),

        _CodeSnippetCard(
          title: 'LangChain Integration Snippet',
          lang: 'python',
          code: langChainSnippet,
        ),
      ],
    );
  }
}

// ── Shared Preset UI Helpers ────────────────────────────────────────────────

class _PresetIntro extends StatelessWidget {
  final String title;
  final String description;
  final String badge;

  const _PresetIntro({
    required this.title,
    required this.description,
    required this.badge,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: GoogleFonts.inter(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                  color: t.text,
                ),
              ),
            ),
            AppTag(badge, color: t.accent),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          description,
          style: t.caption.copyWith(height: 1.4),
        ),
      ],
    );
  }
}

class _PresetValueRow extends StatelessWidget {
  final String label;
  final String value;
  final String tooltip;
  final bool isSecret;
  final bool obscure;
  final VoidCallback? onToggleObscure;

  const _PresetValueRow({
    required this.label,
    required this.value,
    required this.tooltip,
    this.isSecret = false,
    this.obscure = false,
    this.onToggleObscure,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final displayedValue =
        isSecret && obscure ? '•' * (value.length.clamp(12, 28)) : value;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label, style: t.small),
                const SizedBox(height: 3),
                Text(
                  displayedValue,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.mono.copyWith(fontSize: 13, color: t.text),
                ),
              ],
            ),
          ),
          if (isSecret && onToggleObscure != null)
            IconButton(
              tooltip: obscure ? 'Show key' : 'Hide key',
              visualDensity: VisualDensity.compact,
              icon: Icon(
                obscure
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                size: 17,
                color: t.muted,
              ),
              onPressed: onToggleObscure,
            ),
          _AnimatedCopyButton(
            text: value,
            label: label,
            tooltip: tooltip,
          ),
        ],
      ),
    );
  }
}

class _CodeSnippetCard extends StatelessWidget {
  final String title;
  final String lang;
  final String code;

  const _CodeSnippetCard({
    required this.title,
    required this.lang,
    required this.code,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);

    return Container(
      decoration: BoxDecoration(
        color: t.isDark ? const Color(0xFF0F0F11) : const Color(0xFFF6F6F8),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.hairline, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header Bar
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: t.fill,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    lang.toUpperCase(),
                    style: t.mono.copyWith(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: t.muted,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: t.small.copyWith(
                      fontWeight: FontWeight.w600,
                      color: t.text,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                _AnimatedCopyButton(
                  text: code,
                  label: title,
                  tooltip: 'Copy code snippet',
                ),
              ],
            ),
          ),
          Divider(height: 1, thickness: 0.5, color: t.hairline),
          // Code Display Area
          Padding(
            padding: const EdgeInsets.all(14),
            child: SelectableText(
              code,
              style: GoogleFonts.firaCode(
                fontSize: 12,
                height: 1.5,
                color: t.isDark ? const Color(0xFFE5E5EA) : const Color(0xFF1C1C1E),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AnimatedCopyButton extends StatefulWidget {
  final String text;
  final String label;
  final String tooltip;

  const _AnimatedCopyButton({
    required this.text,
    required this.label,
    required this.tooltip,
  });

  @override
  State<_AnimatedCopyButton> createState() => _AnimatedCopyButtonState();
}

class _AnimatedCopyButtonState extends State<_AnimatedCopyButton> {
  bool _copied = false;
  Timer? _timer;

  Future<void> _handleCopy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    Haptics.lightImpact();
    showToast(
      'Copied to clipboard',
      widget.label,
      tone: ToastTone.success,
    );
    if (!mounted) return;
    setState(() => _copied = true);
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);

    return IconButton(
      tooltip: _copied ? 'Copied' : widget.tooltip,
      visualDensity: VisualDensity.compact,
      onPressed: _handleCopy,
      icon: AnimatedSwitcher(
        duration: const Duration(milliseconds: 160),
        transitionBuilder: (child, anim) =>
            ScaleTransition(scale: anim, child: child),
        child: _copied
            ? Icon(
                Icons.check_rounded,
                key: const ValueKey('check'),
                size: 17,
                color: t.green,
              )
            : Icon(
                Icons.copy_rounded,
                key: const ValueKey('copy'),
                size: 16,
                color: t.muted,
              ),
      ),
    );
  }
}

class _CopyAllBar extends StatefulWidget {
  final String label;
  final String content;
  final String toastSubtitle;

  const _CopyAllBar({
    required this.label,
    required this.content,
    required this.toastSubtitle,
  });

  @override
  State<_CopyAllBar> createState() => _CopyAllBarState();
}

class _CopyAllBarState extends State<_CopyAllBar> {
  bool _copied = false;
  Timer? _timer;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.content));
    Haptics.lightImpact();
    showToast('Copied', widget.toastSubtitle, tone: ToastTone.success);
    if (!mounted) return;
    setState(() => _copied = true);
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);

    return Material(
      color: t.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: _copied ? t.green : t.hairline, width: 0.5),
      ),
      child: InkWell(
        onTap: _copy,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                _copied ? Icons.check_circle_rounded : Icons.copy_rounded,
                size: 16,
                color: _copied ? t.green : t.accent,
              ),
              const SizedBox(width: 8),
              Text(
                _copied ? 'Copied to Clipboard!' : widget.label,
                style: t.bodyStrong.copyWith(
                  fontSize: 13,
                  color: _copied ? t.green : t.text,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  final int stepNumber;
  final String instruction;

  const _StepRow({
    required this.stepNumber,
    required this.instruction,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: t.fill,
              shape: BoxShape.circle,
              border: Border.all(color: t.hairline, width: 0.5),
            ),
            child: Text(
              '$stepNumber',
              style: t.mono.copyWith(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: t.text,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              instruction,
              style: t.caption.copyWith(color: t.text, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}
