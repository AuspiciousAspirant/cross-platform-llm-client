import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_fonts/google_fonts.dart';
import '../controllers/chat_controller.dart';
import '../controllers/settings_controller.dart';
import '../controllers/model_controller.dart';
import '../controllers/home_controller.dart';
import '../services/cluster_service.dart';
import '../services/inference_service.dart';
import '../services/local_image_service.dart';
import '../ffi/sd_ffi_bindings.dart';
import '../utils/thought_parser.dart';
import '../widgets/attachment_preview.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/chat_drawer.dart';
import '../widgets/home_empty_state.dart';
import '../core/ui.dart';
import '../widgets/thought_disclosure.dart';
import '../core/haptics.dart';

// ── Apple-style color helpers ──
Color _appleBlue(BuildContext c) => Theme.of(c).brightness == Brightness.dark
    ? const Color(0xFF0A84FF)
    : const Color(0xFF007AFF);

Color _aiBubble(BuildContext c) => Theme.of(c).brightness == Brightness.dark
    ? const Color(0xFF1C1C1E)
    : const Color(0xFFF2F2F7);

Color _sep(BuildContext c) => Theme.of(c).brightness == Brightness.dark
    ? Colors.white.withValues(alpha: 0.08)
    : Colors.black.withValues(alpha: 0.08);

class ChatView extends GetView<ChatController> {
  const ChatView({super.key});

  bool _isDesktopEnvironment(BuildContext context) {
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      return true;
    }
    return MediaQuery.of(context).size.width >= 800;
  }

  void _insertComposerNewline() {
    final text = controller.textController.text;
    final selection = controller.textController.selection;
    final newText = StringBuffer();
    int newCursorPosition = 0;

    if (selection.isValid && selection.start >= 0) {
      newText.write(text.substring(0, selection.start));
      newText.write('\n');
      newText.write(text.substring(selection.end));
      newCursorPosition = selection.start + 1;
    } else {
      newText.write(text);
      newText.write('\n');
      newCursorPosition = newText.length;
    }

    controller.textController.value = TextEditingValue(
      text: newText.toString(),
      selection: TextSelection.collapsed(offset: newCursorPosition),
    );
    controller.inputText.value = controller.textController.text;
  }

  KeyEventResult _handleComposerKeyEvent(
      FocusNode node, KeyEvent event, bool isDesktop) {
    if (!isDesktop) return KeyEventResult.ignored;

    final isEnter = event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;

    if (!isEnter) return KeyEventResult.ignored;

    if (event is KeyDownEvent) {
      final isShift = HardwareKeyboard.instance.isShiftPressed;
      if (isShift) {
        _insertComposerNewline();
        return KeyEventResult.handled;
      } else {
        final text = controller.textController.text.trim();
        final isGenerating =
            controller.isLoading.value || controller.isStreaming.value;
        if (text.isNotEmpty && !isGenerating) {
          controller.sendMessage();
        }
        return KeyEventResult.handled;
      }
    } else if (event is KeyRepeatEvent) {
      final isShift = HardwareKeyboard.instance.isShiftPressed;
      if (isShift) {
        _insertComposerNewline();
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }

    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isDesktop = MediaQuery.of(context).size.width >= 900;

    Widget chatScaffold = Scaffold(
      backgroundColor: isDark ? Colors.black : Colors.white,
      drawer: isDesktop ? null : const ChatDrawer(),
      appBar: _appBar(context, isDark, isDesktop: isDesktop),
      body: Column(
        children: [
          _modelLoadingBar(context, isDark),
          _workerDropBanner(context, isDark),
          Expanded(child: Obx(() {
            if (controller.currentSessionId.value.isEmpty ||
                controller.messages.isEmpty) {
              return _emptyState(context, isDark);
            }
            final streaming = controller.isStreaming.value;
            final text = controller.streamingResponse.value;
            final n = controller.messages.length;
            return NotificationListener<ScrollUpdateNotification>(
              onNotification: (note) {
                if (note.dragDetails != null && streaming) {
                  if ((note.scrollDelta ?? 0) < 0) {
                    controller.pauseStreamingFollow();
                  } else {
                    controller.resumeStreamingFollowIfNearBottom();
                  }
                }
                return false;
              },
              child: ListView.builder(
                controller: controller.scrollController,
                padding: const EdgeInsets.only(top: 8, bottom: 8),
                itemCount: n + (streaming ? 1 : 0),
                itemBuilder: (_, i) {
                  final Widget item;
                  if (i == n && streaming) {
                    item = _streamBubble(context, text, isDark);
                  } else {
                    item = ChatBubble(message: controller.messages[i]);
                  }
                  return Align(
                    alignment: Alignment.center,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 860),
                      child: item,
                    ),
                  );
                },
              ),
            );
          })),
          _inputBar(context, isDark),
        ],
      ),
    );

    Widget body;
    if (isDesktop) {
      body = Row(
        children: [
          const SizedBox(
            width: 280,
            child: ChatDrawer(isDocked: true),
          ),
          VerticalDivider(
            width: 0.5,
            thickness: 0.5,
            color: _sep(context),
          ),
          Expanded(child: chatScaffold),
        ],
      );
    } else {
      body = chatScaffold;
    }

    if (Platform.isIOS) {
      return GestureDetector(
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        behavior: HitTestBehavior.translucent,
        child: body,
      );
    }
    return body;
  }

  // ── AppBar ──
  PreferredSizeWidget _appBar(BuildContext context, bool isDark,
      {bool isDesktop = false}) {
    return AppBar(
      backgroundColor: isDark ? Colors.black : Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      automaticallyImplyLeading: false,
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(0.5),
        child: Obx(() => Container(
            height: 0.5,
            color: controller.messages.isEmpty
                ? Colors.transparent
                : _sep(context))),
      ),
      titleSpacing: isDesktop ? 20 : 0,
      leadingWidth: isDesktop ? 0 : 52,
      leading: isDesktop
          ? null
          : IconButton(
              tooltip: 'Chats',
              onPressed: () {
                FocusManager.instance.primaryFocus?.unfocus();
                Get.find<HomeController>().openSidebar();
              },
              icon: SidebarGlyph(color: isDark ? Colors.white : Colors.black),
            ),
      title: Obx(() {
        final text = isDark ? Colors.white : Colors.black;
        // Home: a quiet wordmark — the model card below carries the status.
        if (controller.messages.isEmpty) {
          return Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Text('PrivateLM',
                style: GoogleFonts.inter(
                    fontWeight: FontWeight.w700,
                    fontSize: 18,
                    letterSpacing: -0.5,
                    color: text)),
          );
        }
        final sid = controller.currentSessionId.value;
        final info = _modelInfo(context);
        final title =
            controller.sessions.firstWhereOrNull((s) => s.id == sid)?.title ??
                'Chat';
        // Title + model line; tapping opens the model sheet.
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _showModelSheet(context),
          child: Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.inter(
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                          letterSpacing: -0.3,
                          color: text)),
                  const SizedBox(height: 1),
                  Row(children: [
                    Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                            shape: BoxShape.circle, color: info.dot)),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(info.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(
                              fontSize: 12.5,
                              color: Theme.of(context).hintColor)),
                    ),
                    Icon(Icons.expand_more_rounded,
                        size: 16, color: Theme.of(context).hintColor),
                  ]),
                ]),
          ),
        );
      }),
      actions: [
        _clusterTelemetryPill(context, isDark),
        Obx(() {
          if (controller.messages.isEmpty) return const SizedBox.shrink();
          final usage = _contextUsage();
          if (usage == null) return const SizedBox.shrink();
          final warn = usage.pct >= 0.75;
          return IconButton(
            tooltip: 'Context ${(usage.pct * 100).round()}% used',
            onPressed: () => _showModelSheet(context),
            icon: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                value: usage.pct < 0.02 ? 0.02 : usage.pct,
                strokeWidth: 2.4,
                strokeCap: StrokeCap.round,
                backgroundColor: _sep(context),
                color: warn
                    ? const Color(0xFFFF9500)
                    : Theme.of(context).hintColor,
              ),
            ),
          );
        }),
        Obx(() {
          // Already on a blank chat — a "new chat" button would only create
          // empty sessions.
          if (controller.messages.isEmpty) return const SizedBox(width: 8);
          return IconButton(
              tooltip: _isDesktopEnvironment(context)
                  ? 'New chat (Ctrl+N / ⌘N)'
                  : 'New chat',
              icon: Icon(Icons.edit_square,
                  size: 20, color: isDark ? Colors.white : Colors.black),
              onPressed: () {
                Haptics.selectionClick();
                controller.createNewChat();
              });
        }),
        const SizedBox(width: 4),
      ],
    );
  }

  /// Name and status colour of whatever will answer the next message.
  ({String name, String meta, Color dot, bool canUnload}) _modelInfo(
      BuildContext context) {
    final settings = Get.find<SettingsController>();
    final inf = Get.find<InferenceService>();
    final img = Get.find<LocalImageService>();
    const green = Color(0xFF34C759);
    const orange = Color(0xFFFF9500);
    String pretty(String n) => n.replaceAll(
        RegExp(r'\.(gguf|litertlm|task|bin)$', caseSensitive: false), '');

    if (settings.inferenceMode.value != 'local') {
      final m = settings.selectedCloudModelName;
      return (
        name: m.isEmpty ? 'No model selected' : m,
        meta: 'Cloud · ${providerLabel(settings)}',
        dot: _appleBlue(context),
        canUnload: false,
      );
    }
    if (inf.isLoadingModel.value) {
      return (
        name: 'Loading model…',
        meta: '${(inf.modelLoadProgress.value * 100).round()}%',
        dot: orange,
        canUnload: false,
      );
    }
    if (inf.isModelLoaded.value) {
      return (
        name: pretty(inf.loadedModelName.value),
        meta: [
          'Ready',
          Get.isRegistered<ClusterService>()
              ? Get.find<ClusterService>().splitSummary ??
                  (inf.isGpuAccelerated.value ? 'GPU' : 'CPU')
              : (inf.isGpuAccelerated.value ? 'GPU' : 'CPU'),
          inf.loadedModelRuntime.value == 'litert' ? 'LiteRT' : 'GGUF',
        ].join(' · '),
        dot: green,
        canUnload: true,
      );
    }
    if (img.isModelLoaded.value) {
      final b = img.currentBackend.value;
      return (
        name: pretty(img.loadedModelName.value),
        meta:
            'Ready · Image generation · ${b == Backend.cpu ? 'CPU' : b.displayName.split(' ').first}',
        dot: green,
        canUnload: true,
      );
    }
    return (
      name: 'No model loaded',
      meta: 'Load a model to continue this chat',
      dot: orange,
      canUnload: false,
    );
  }

  /// Local context-window usage, or null when it doesn't apply.
  ({int used, int total, double pct})? _contextUsage() {
    final settings = Get.find<SettingsController>();
    final inf = Get.find<InferenceService>();
    if (settings.inferenceMode.value != 'local' || !inf.isModelLoaded.value) {
      return null;
    }
    final total = inf.contextTokensTotal.value > 0
        ? inf.contextTokensTotal.value
        : settings.contextSize.value;
    final est =
        controller.messages.fold<int>(0, (s, m) => s + m.content.length);
    final used = (inf.contextTokensUsed.value > 0
            ? inf.contextTokensUsed.value
            : (est / 4).ceil())
        .clamp(0, total)
        .toInt();
    final pct = total == 0 ? 0.0 : (used / total).clamp(0.0, 1.0).toDouble();
    return (used: used, total: total, pct: pct);
  }

  // ── Model sheet ──
  void _showModelSheet(BuildContext context) {
    Haptics.selectionClick();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? const Color(0xFF1C1C1E) : Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
          child: Obx(() {
            final info = _modelInfo(ctx);
            final usage = _contextUsage();
            final text = isDark ? Colors.white : const Color(0xFF0B0B0C);
            final muted = Theme.of(ctx).hintColor;
            final warn = (usage?.pct ?? 0) >= 0.75;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                        color: _sep(ctx).withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                const SizedBox(height: 18),
                Text('Model',
                    style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: muted)),
                const SizedBox(height: 6),
                Text(info.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.inter(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.3,
                        color: text)),
                const SizedBox(height: 4),
                Row(children: [
                  Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                          shape: BoxShape.circle, color: info.dot)),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(info.meta,
                        style: GoogleFonts.inter(fontSize: 13, color: muted)),
                  ),
                ]),
                if (usage != null) ...[
                  const SizedBox(height: 22),
                  Row(children: [
                    Expanded(
                      child: Text('Context',
                          style: GoogleFonts.inter(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: muted)),
                    ),
                    Text('${_fmtK(usage.used)} / ${_fmtK(usage.total)} tokens',
                        style: GoogleFonts.inter(
                            fontSize: 13,
                            color: warn ? const Color(0xFFFF9500) : muted,
                            fontFeatures: const [
                              FontFeature.tabularFigures()
                            ])),
                  ]),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: usage.pct,
                      minHeight: 5,
                      backgroundColor: isDark
                          ? Colors.white.withValues(alpha: 0.08)
                          : Colors.black.withValues(alpha: 0.06),
                      color: warn ? const Color(0xFFFF9500) : _appleBlue(ctx),
                    ),
                  ),
                  if (warn) ...[
                    const SizedBox(height: 8),
                    Text('Almost full. Start a new chat for best results.',
                        style: GoogleFonts.inter(fontSize: 12.5, color: muted)),
                  ],
                ],
                const SizedBox(height: 24),
                Row(children: [
                  Expanded(
                    child: TonalButton.neutral(ctx, label: 'Switch model',
                        onTap: () {
                      Navigator.pop(ctx);
                      Get.find<HomeController>().changeTab(1);
                    }),
                  ),
                  if (info.canUnload) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: TonalButton.destructive(ctx, label: 'Unload',
                          onTap: () {
                        Navigator.pop(ctx);
                        Get.find<ModelController>().unloadModel();
                      }),
                    ),
                  ],
                ]),
              ],
            );
          }),
        ),
      ),
    );
  }

  // ── Model Loading ──
  Widget _modelLoadingBar(BuildContext context, bool isDark) {
    return Obx(() {
      final inf = Get.find<InferenceService>();
      if (!inf.isLoadingModel.value) return const SizedBox.shrink();
      final pct = (inf.modelLoadProgress.value * 100).round();
      return Align(
        alignment: Alignment.center,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(
                  child: Text('Loading model',
                      style: GoogleFonts.inter(
                          fontSize: 12.5,
                          color: Theme.of(context).hintColor,
                          fontWeight: FontWeight.w500)),
                ),
                Text('$pct%',
                    style: GoogleFonts.inter(
                        fontSize: 12.5,
                        color: Theme.of(context).hintColor,
                        fontFeatures: const [FontFeature.tabularFigures()])),
              ]),
              const SizedBox(height: 6),
              ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                      value: inf.modelLoadProgress.value,
                      backgroundColor: _sep(context),
                      color: _appleBlue(context),
                      minHeight: 3)),
            ]),
          ),
        ),
      );
    });
  }

  // ── Cluster Worker Drop Fallback Banner ──
  Widget _workerDropBanner(BuildContext context, bool isDark) {
    if (!Get.isRegistered<ClusterService>()) return const SizedBox.shrink();
    final cluster = Get.find<ClusterService>();

    return Obx(() {
      if (cluster.droppedWorkers.isEmpty) return const SizedBox.shrink();
      final droppedList = cluster.droppedWorkers.join(', ');

      return Align(
        alignment: Alignment.center,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(16, 6, 16, 6),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFFFF9500)
                  .withValues(alpha: isDark ? 0.14 : 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: const Color(0xFFFF9500)
                    .withValues(alpha: isDark ? 0.35 : 0.25),
                width: 0.5,
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  size: 20,
                  color: Color(0xFFFF9500),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Cluster worker unreachable ($droppedList). Generation may be degraded.',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: isDark ? Colors.white : const Color(0xFF1C1C1E),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                _ClusterFallbackButton(cluster: cluster, isDark: isDark),
              ],
            ),
          ),
        ),
      );
    });
  }

  // ── Cluster Telemetry Pill in AppBar ──
  Widget _clusterTelemetryPill(BuildContext context, bool isDark) {
    if (!Get.isRegistered<ClusterService>()) return const SizedBox.shrink();
    final cluster = Get.find<ClusterService>();

    return Obx(() {
      if (cluster.split.isEmpty) return const SizedBox.shrink();
      final inf = Get.find<InferenceService>();
      final tokPerSec = inf.tokensPerSecond.value;
      final latency = cluster.clusterLatencyMs.value;
      final isHealthy = cluster.isClusterHealthy.value;
      final nodeCount = cluster.split.length;

      final Color dotColor;
      if (!isHealthy) {
        dotColor = const Color(0xFFFF3B30); // Red
      } else if (latency > 75) {
        dotColor = const Color(0xFFFF9500); // Amber
      } else {
        dotColor = const Color(0xFF34C759); // Green
      }

      final speedText = tokPerSec > 0
          ? '${tokPerSec.toStringAsFixed(1)} tok/s'
          : 'Ready';
      final latencyText = latency > 0 ? ' · ${latency}ms' : '';
      final pillText = '⚡ $nodeCount Nodes · $speedText$latencyText';

      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: Tooltip(
          message: 'Inspect LAN Cluster Topology',
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () {
                Haptics.selectionClick();
                _showClusterTopologySheet(context);
              },
              borderRadius: BorderRadius.circular(14),
              child: Container(
                height: 28,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF161618)
                      : const Color(0xFFF4F4F5),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.1)
                        : Colors.black.withValues(alpha: 0.08),
                    width: 0.5,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: dotColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 7),
                    Text(
                      pillText,
                      style: GoogleFonts.firaCode(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                        color: isDark ? Colors.white : const Color(0xFF0B0B0C),
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    });
  }

  // ── Cluster Topology Inspector Modal ──
  void _showClusterTopologySheet(BuildContext context) {
    if (!Get.isRegistered<ClusterService>()) return;
    Haptics.selectionClick();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cluster = Get.find<ClusterService>();
    final inf = Get.find<InferenceService>();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDark ? const Color(0xFF141416) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.88,
            maxWidth: 860,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
            child: Obx(() {
              final shares = cluster.split;
              final text = isDark ? Colors.white : const Color(0xFF0B0B0C);
              final muted = Theme.of(ctx).hintColor;
              final borderCol = isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.black.withValues(alpha: 0.06);
              final cardBg = isDark
                  ? const Color(0xFF1C1C1E)
                  : const Color(0xFFF7F7F8);
              final totalMb = shares.fold<double>(0, (a, s) => a + s.mb);
              final nodeCount = shares.length;
              final isHealthy = cluster.isClusterHealthy.value;

              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Handle pill
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: _sep(ctx).withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Title + Node Count Badge + Health Status
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Text(
                            'Cluster Topology & LAN Telemetry',
                            style: GoogleFonts.inter(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.3,
                              color: text,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: _appleBlue(ctx).withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: _appleBlue(ctx).withValues(alpha: 0.25),
                                width: 0.5,
                              ),
                            ),
                            child: Text(
                              '$nodeCount ${nodeCount == 1 ? "Node" : "Nodes"}',
                              style: GoogleFonts.inter(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: _appleBlue(ctx),
                              ),
                            ),
                          ),
                        ],
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 9, vertical: 4),
                        decoration: BoxDecoration(
                          color: (isHealthy
                                  ? const Color(0xFF34C759)
                                  : const Color(0xFFFF3B30))
                              .withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: (isHealthy
                                    ? const Color(0xFF34C759)
                                    : const Color(0xFFFF3B30))
                                .withValues(alpha: 0.25),
                            width: 0.5,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: isHealthy
                                    ? const Color(0xFF34C759)
                                    : const Color(0xFFFF3B30),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              isHealthy ? 'Healthy' : 'Degraded',
                              style: GoogleFonts.inter(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: isHealthy
                                    ? const Color(0xFF34C759)
                                    : const Color(0xFFFF3B30),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Real-time tensor distribution & layer pipeline across local network',
                    style: GoogleFonts.inter(fontSize: 12.5, color: muted),
                  ),
                  const SizedBox(height: 18),

                  // Pipeline Visualizer (Horizontal execution order)
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        for (int i = 0; i < shares.length; i++) ...[
                          _buildPipelineNodeCard(
                            ctx,
                            shares[i],
                            index: i + 1,
                            totalMb: totalMb,
                            isDark: isDark,
                            cardBg: cardBg,
                            borderCol: borderCol,
                            text: text,
                            muted: muted,
                          ),
                          if (i < shares.length - 1)
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 10),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.arrow_forward_rounded,
                                    size: 18,
                                    color: muted.withValues(alpha: 0.6),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'RPC',
                                    style: GoogleFonts.inter(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                      color: muted.withValues(alpha: 0.6),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),

                  const SizedBox(height: 20),
                  Divider(height: 0.5, thickness: 0.5, color: borderCol),
                  const SizedBox(height: 16),

                  // Footer Metrics Row
                  Row(
                    children: [
                      // Metric 1: Live Speed
                      _buildFooterMetric(
                        ctx,
                        label: 'Generation Speed',
                        value: inf.tokensPerSecond.value > 0
                            ? '${inf.tokensPerSecond.value.toStringAsFixed(1)} tok/s'
                            : 'Idle',
                        icon: Icons.speed_rounded,
                        text: text,
                        muted: muted,
                      ),
                      const SizedBox(width: 20),

                      // Metric 2: Combined Memory
                      _buildFooterMetric(
                        ctx,
                        label: 'Cluster Memory',
                        value: _fmtMb(totalMb),
                        icon: Icons.memory_rounded,
                        text: text,
                        muted: muted,
                      ),
                      const SizedBox(width: 20),

                      // Metric 3: Roundtrip Ping
                      _buildFooterMetric(
                        ctx,
                        label: 'Network Roundtrip',
                        value: cluster.clusterLatencyMs.value > 0
                            ? '${cluster.clusterLatencyMs.value}ms avg'
                            : (shares.length <= 1 ? '0ms (Local)' : '<1ms'),
                        icon: Icons.network_ping_rounded,
                        text: text,
                        muted: muted,
                      ),
                      const Spacer(),

                      // Action: Re-test Pings button
                      _RetestPingsButton(cluster: cluster, isDark: isDark),
                    ],
                  ),
                ],
              );
            }),
          ),
        ),
      ),
    );
  }

  Widget _buildPipelineNodeCard(
    BuildContext context,
    ClusterShare share, {
    required int index,
    required double totalMb,
    required bool isDark,
    required Color cardBg,
    required Color borderCol,
    required Color text,
    required Color muted,
  }) {
    final pct = totalMb > 0 ? (share.mb / totalMb * 100).round() : 0;
    final isMaster = share.isThisPhone;

    // Ping status
    final Color pingColor;
    final String pingLabel;
    if (isMaster) {
      pingColor = const Color(0xFF34C759);
      pingLabel = 'Local (0ms)';
    } else if (share.pingMs != null && share.isHealthy) {
      pingColor = share.pingMs! > 75
          ? const Color(0xFFFF9500)
          : const Color(0xFF34C759);
      pingLabel = '${share.pingMs}ms';
    } else {
      pingColor = const Color(0xFFFF3B30);
      pingLabel = 'Offline';
    }

    final layerText = (share.startLayer != 0 || share.endLayer != 0)
        ? 'Layers ${share.startLayer}–${share.endLayer}'
        : (isMaster ? 'Root & Master Layers' : 'Offloaded Layers');

    final endpointText = share.endpoint.isNotEmpty
        ? share.endpoint
        : (isMaster ? 'Local Host' : '127.0.0.1:50052');

    return Container(
      width: 235,
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: !share.isHealthy && !isMaster
              ? const Color(0xFFFF3B30).withValues(alpha: 0.45)
              : borderCol,
          width: 0.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Top Row: Node Name + Role Badge
          Row(
            children: [
              Icon(
                isMaster
                    ? (Platform.isAndroid || Platform.isIOS
                        ? Icons.smartphone_rounded
                        : Icons.computer_rounded)
                    : Icons.dns_rounded,
                size: 16,
                color: isMaster ? _appleBlue(context) : muted,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  share.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: text,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: (isMaster ? _appleBlue(context) : muted)
                      .withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  isMaster ? 'Master' : 'Worker',
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: isMaster ? _appleBlue(context) : muted,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Assigned layers
          Row(
            children: [
              Icon(Icons.layers_outlined, size: 14, color: muted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  layerText,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: text,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),

          // Memory share
          Row(
            children: [
              Icon(Icons.pie_chart_outline_rounded, size: 14, color: muted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${_fmtMb(share.mb)} ($pct%)',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    color: muted,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Endpoint & LAN Ping Badge
          Row(
            children: [
              Expanded(
                child: Text(
                  endpointText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.firaCode(
                    fontSize: 10.5,
                    color: muted.withValues(alpha: 0.8),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: pingColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: pingColor.withValues(alpha: 0.25),
                    width: 0.5,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: pingColor,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      pingLabel,
                      style: GoogleFonts.firaCode(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w500,
                        color: pingColor,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFooterMetric(
    BuildContext context, {
    required String label,
    required String value,
    required IconData icon,
    required Color text,
    required Color muted,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: muted),
            const SizedBox(width: 4),
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: muted,
              ),
            ),
          ],
        ),
        const SizedBox(height: 3),
        Text(
          value,
          style: GoogleFonts.firaCode(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: text,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  static String _fmtMb(double mb) {
    if (mb >= 1024) {
      return '${(mb / 1024).toStringAsFixed(1)} GB';
    }
    return '${mb.round()} MB';
  }

  // ── Empty State ──
  Widget _emptyState(BuildContext context, bool isDark) =>
      const HomeEmptyState();

  // ── Streaming Bubble ──
  Widget _streamBubble(BuildContext context, String text, bool isDark) {
    final attType = controller.streamingAttachmentType.value;
    final isImageGen = controller.imageGenTotal.value > 0;
    final clean = _cleanStream(text).trimLeft();
    final parts = splitThoughtTags(clean);
    final answer = parts.answer.trimLeft();
    final hasText = parts.hasThought || _hasPrintable(answer);

    // Matches ChatBubble's assistant layout: full-width text, no bubble.
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (isImageGen)
          Container(
            constraints: BoxConstraints(
                maxWidth:
                    math.min(MediaQuery.of(context).size.width * 0.82, 720.0)),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _aiBubble(context),
              borderRadius: BorderRadius.circular(16),
            ),
            child: _ImageGenIndicator(controller: controller, isDark: isDark),
          )
        else if (!hasText)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: _typingHint(context, isDark, attachmentType: attType),
          )
        else ...[
          if (parts.hasThought)
            ThoughtDisclosure(
                thought: parts.thought,
                isThinking: parts.isThinking,
                styleSheet: _thoughtMd(context, isDark)),
          if (_hasPrintable(answer))
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Expanded(
                  child: MarkdownBody(
                      data: answer,
                      selectable: true,
                      styleSheet: _streamMd(context, isDark))),
              _BlinkingCursor(color: Theme.of(context).hintColor),
            ]),
        ],
        if (hasText && !isImageGen)
          Obx(() {
            final inf = Get.find<InferenceService>();
            if (inf.tokensPerSecond.value <= 0) {
              return const SizedBox(height: 28);
            }
            return SizedBox(
              height: 28,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                    '${inf.tokensPerSecond.value.toStringAsFixed(1)} tok/s',
                    style: GoogleFonts.inter(
                        fontSize: 12,
                        color:
                            Theme.of(context).hintColor.withValues(alpha: 0.8),
                        fontFeatures: const [FontFeature.tabularFigures()])),
              ),
            );
          }),
      ]),
    );
  }

  Widget _typingHint(BuildContext context, bool isDark,
      {String? attachmentType}) {
    final msg = attachmentType == 'image'
        ? 'Reading image…'
        : attachmentType == 'audio'
            ? 'Listening to audio…'
            : null;
    if (msg == null) return _TypingDots(isDark: isDark);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      _TypingDots(isDark: isDark),
      const SizedBox(width: 10),
      Flexible(
          child: Text(msg,
              style: GoogleFonts.inter(
                  fontSize: 12,
                  color: Theme.of(context).hintColor,
                  fontWeight: FontWeight.w400))),
    ]);
  }

  // ── Input Bar ──
  Widget _inputBar(BuildContext context, bool isDark) {
    final isDesktop = _isDesktopEnvironment(context);
    return Container(
      color: isDark ? Colors.black : Colors.white,
      child: SafeArea(
        top: false,
        child: Align(
          alignment: Alignment.center,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            // Attachment preview
            Obx(() {
              final name = controller.selectedFileName.value;
              if (name == null) return const SizedBox.shrink();
              return Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                  child: AttachmentPreview(
                    fileName: name,
                    fileType: controller.selectedFileType.value,
                    fileSize: controller.selectedFileSize.value > 0
                        ? controller.selectedFileSize.value
                        : null,
                    imagePath: controller.selectedImagePath.value,
                    imageBase64: controller.selectedImageBase64.value,
                    onRemove: () {
                      controller.clearImage();
                      controller.clearFile();
                    },
                  ));
            }),
            // STT listening indicator
            Obx(() {
              if (!controller.isListening.value) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF3B30).withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: const Color(0xFFFF3B30).withValues(alpha: 0.3)),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const _PulsingDot(),
                    const SizedBox(width: 8),
                    Text('Listening… tap mic to stop',
                        style: GoogleFonts.inter(
                            fontSize: 12,
                            color: const Color(0xFFFF3B30),
                            fontWeight: FontWeight.w500)),
                  ]),
                ),
              );
            }),
            Obx(() {
              final settings = Get.find<SettingsController>();
              final localImage = Get.find<LocalImageService>();
              if (settings.inferenceMode.value != 'local' ||
                  !localImage.isModelLoaded.value) {
                return const SizedBox.shrink();
              }
              final steps = settings.imageSteps.value;
              final size = settings.imageGenSize.value;
              final sizeLabel = size == 0 ? 'Auto' : '${size}px';
              final backend = localImage.currentBackend.value;
              final backendLabel = backend == Backend.cpu
                  ? 'CPU'
                  : (backend == Backend.metal
                      ? 'APPLE NPU'
                      : backend.displayName.split(' ').first.toUpperCase());
              final accent = backend == Backend.cpu
                  ? const Color(0xFFFF9500)
                  : const Color(0xFF34C759);
              return Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: accent.withValues(alpha: 0.24),
                            width: 0.5,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.auto_awesome_rounded,
                                size: 13, color: accent),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                'Image gen · $steps ${steps == 1 ? "step" : "steps"} · $sizeLabel · $backendLabel',
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.inter(
                                  fontSize: 11,
                                  color: accent,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      height: 30,
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.06)
                            : Colors.black.withValues(alpha: 0.04),
                        borderRadius: BorderRadius.circular(15),
                        border: Border.all(color: _sep(context), width: 0.5),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _StepButton(
                            icon: Icons.remove_rounded,
                            enabled: steps > 1,
                            onTap: () => settings.setImageSteps(steps - 1),
                          ),
                          Text(
                            steps.toString(),
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              color: isDark ? Colors.white : Colors.black,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          _StepButton(
                            icon: Icons.add_rounded,
                            enabled: steps < 20,
                            onTap: () => settings.setImageSteps(steps + 1),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }),
            Obx(() {
              if (controller.lastBatchImagesBase64.isEmpty) {
                return const SizedBox.shrink();
              }
              return Container(
                margin: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF34C759).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                      color: const Color(0xFF34C759).withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle_rounded,
                        size: 18, color: Color(0xFF34C759)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Batch complete! (${controller.lastBatchImagesBase64.length} images)',
                        style: GoogleFonts.inter(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                            color: isDark ? Colors.white : Colors.black),
                      ),
                    ),
                    TextButton(
                      onPressed: () => controller.lastBatchImagesBase64.clear(),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        minimumSize: const Size(0, 32),
                        foregroundColor: Theme.of(context).hintColor,
                      ),
                      child: const Text('Dismiss'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: () => controller.downloadLastBatch(),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF34C759),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        minimumSize: const Size(0, 32),
                      ),
                      icon: const Icon(Icons.download_rounded, size: 16),
                      label: const Text('Save All'),
                    ),
                  ],
                ),
              );
            }),
            Obx(() {
              if (controller.batchPrompts.isEmpty) {
                return const SizedBox.shrink();
              }
              return Container(
                margin: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: _appleBlue(context).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                      color: _appleBlue(context).withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.layers_rounded,
                        size: 18, color: _appleBlue(context)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${controller.batchPrompts.length}/20 batch prompts',
                        style: GoogleFonts.inter(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                            color: isDark ? Colors.white : Colors.black),
                      ),
                    ),
                    TextButton(
                      onPressed: () => controller.batchPrompts.clear(),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        minimumSize: const Size(0, 32),
                        foregroundColor: Colors.redAccent,
                      ),
                      child: const Text('Clear'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: controller.isLoading.value
                          ? null
                          : () => controller.generateBatch(),
                      style: FilledButton.styleFrom(
                        backgroundColor: _appleBlue(context),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        minimumSize: const Size(0, 32),
                      ),
                      child: const Text('Start Batch'),
                    ),
                  ],
                ),
              );
            }),
            // Composer: one rounded surface holding the field and its actions.
            Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF141416)
                      : const Color(0xFFF5F5F7),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.09)
                          : Colors.black.withValues(alpha: 0.07),
                      width: 0.5),
                ),
                child:
                    Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  // Attach button (image + file) — shown for cloud & local vision
                  Obx(() {
                    final s = Get.find<SettingsController>();
                    final inf = Get.find<InferenceService>();
                    final isCloud = s.inferenceMode.value == 'cloud';
                    // LiteRT vision models or GGUF models with a vision
                    // projector can take photos.
                    final isLocalVision = s.inferenceMode.value == 'local' &&
                        inf.isVisionLoaded.value;
                    // Audio files only work with cloud and LiteRT models.
                    final audioOk = isCloud ||
                        (isLocalVision &&
                            inf.loadedModelRuntime.value == 'litert');
                    // Any local text model can read documents: their text is
                    // extracted and inlined into the prompt.
                    final isLocalText = s.inferenceMode.value == 'local' &&
                        inf.isModelLoaded.value;
                    if (!isCloud && !isLocalText) {
                      return const SizedBox.shrink();
                    }
                    final mediaOk = isCloud || isLocalVision;
                    return _AttachButton(
                      isDark: isDark,
                      isCloud: isCloud,
                      allowMedia: mediaOk,
                      onCamera: () =>
                          controller.pickImage(source: ImageSource.camera),
                      onImage: controller.pickImage,
                      onFile: () =>
                          controller.pickFile(documentsOnly: !audioOk),
                      context: context,
                    );
                  }),
                  // Text field
                  // Same 40px base height as the buttons so a single line sits
                  // centred; taller multi-line input keeps buttons at the bottom.
                  Expanded(child: Obx(() {
                    // Local mode with nothing loaded: the field is disabled
                    // and tapping it goes to Models. Cloud mode is unaffected.
                    final noModel = _localModelMissing();
                    final loadingModel =
                        Get.find<InferenceService>().isLoadingModel.value ||
                            Get.find<LocalImageService>().isLoadingModel.value;

                    // Ensure desktop key handler is hooked directly on input focus node
                    if (isDesktop) {
                      controller.inputFocus.onKeyEvent = (node, event) =>
                          _handleComposerKeyEvent(node, event, true);
                    } else {
                      controller.inputFocus.onKeyEvent = null;
                    }

                    final hint = !noModel
                        ? (isDesktop
                            ? 'Ask anything · Enter to send, Shift+Enter for newline'
                            : 'Ask anything')
                        : loadingModel
                            ? 'Loading model…'
                            : 'Load a model to start chatting';

                    return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: noModel && !loadingModel
                            ? () => Get.find<HomeController>().changeTab(1)
                            : null,
                        child: Container(
                          constraints: const BoxConstraints(minHeight: 40),
                          alignment: Alignment.centerLeft,
                          child: Focus(
                            onKeyEvent: (node, event) =>
                                _handleComposerKeyEvent(node, event, isDesktop),
                            child: Tooltip(
                              message: isDesktop && !noModel
                                  ? 'Enter to send, Shift+Enter for newline'
                                  : '',
                              waitDuration: const Duration(milliseconds: 700),
                              child: TextField(
                                enabled: !noModel,
                                controller: controller.textController,
                                focusNode: controller.inputFocus,
                                textCapitalization:
                                    TextCapitalization.sentences,
                                onChanged: (v) =>
                                    controller.inputText.value = v,
                                maxLines: 5,
                                minLines: 1,
                                style: GoogleFonts.inter(
                                    fontSize: 15,
                                    color:
                                        isDark ? Colors.white : Colors.black),
                                decoration: InputDecoration(
                                  hintText: hint,
                                  hintStyle: GoogleFonts.inter(
                                      fontSize: isDesktop ? 13.5 : 15,
                                      color: Theme.of(context).hintColor),
                                  border: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  focusedBorder: InputBorder.none,
                                  disabledBorder: InputBorder.none,
                                  contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 8),
                                  isDense: true,
                                  filled: false,
                                ),
                                onSubmitted: (_) {
                                  if (isDesktop) {
                                    final text =
                                        controller.textController.text.trim();
                                    final isGenerating =
                                        controller.isLoading.value ||
                                            controller.isStreaming.value;
                                    if (text.isNotEmpty && !isGenerating) {
                                      controller.sendMessage();
                                    }
                                  }
                                },
                              ),
                            ),
                          ),
                        ));
                  })),
                  const SizedBox(width: 6),
                  // Batch add button
                  Obx(() {
                    final settings = Get.find<SettingsController>();
                    final localImage = Get.find<LocalImageService>();
                    if (settings.inferenceMode.value == 'local' &&
                        localImage.isModelLoaded.value &&
                        localImage.currentBackend.value == Backend.metal) {
                      return Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: GestureDetector(
                          onLongPress: () {
                            // Testing mode: Populate batch with 15 fresh alternative prompts
                            final testPrompts = [
                              "Portrait of a goth girl with dark makeup, realistic photography, 8k",
                              "Realistic photo of an elf girl in a forest, cinematic lighting",
                              "A fluffy orange cat sleeping on a sunny couch, photorealistic",
                              "A handsome man in a sharp suit, realistic portrait, studio lighting",
                              "A futuristic city street at night, realistic photography",
                              "A beautiful young woman with freckles, natural sunlight",
                              "A majestic lion resting in the savanna, highly detailed",
                              "An old man with a weathered face, realistic portrait, high detail",
                              "A delicious looking cup of coffee on a wooden table, macro photography",
                              "A medieval knight holding a sword, realistic cinematic lighting",
                              "A golden retriever playing fetch, sharp focus, photography",
                              "A realistic cyberpunk character with neon reflections",
                              "A vintage muscle car driving down a desert highway, photorealistic",
                              "A serene mountain lake at sunrise, realistic landscape photography",
                              "A close-up of a beautiful eye with detailed iris, macro shot"
                            ];
                            // Shuffle them before adding
                            testPrompts.shuffle();
                            controller.batchPrompts.clear();
                            controller.batchPrompts.addAll(testPrompts);
                            showToast('Test mode',
                                'Added 15 test prompts to the batch.',
                                tone: ToastTone.success);
                          },
                          onTap: () async {
                            final text = controller.textController.text.trim();
                            if (text.isEmpty) return;
                            if (controller.batchPrompts.length >= 20) {
                              showToast('Batch limit',
                                  'You can add up to 20 prompts per batch.',
                                  tone: ToastTone.warning);
                              return;
                            }
                            if (!controller.batchModeAccepted.value) {
                              final accepted = await confirmSheet(
                                context,
                                title: 'Batch generation',
                                message:
                                    'Generating multiple images back-to-back is demanding. Your device may get warm and use more battery.',
                                confirmLabel: 'Continue',
                              );
                              if (!accepted) return;
                              controller.acceptBatchMode();
                            }
                            controller.batchPrompts.add(text);
                            controller.textController.clear();
                            controller.inputText.value = '';
                          },
                          child: Container(
                            // 3px margins → 40px row height, matching the field.
                            margin: const EdgeInsets.symmetric(vertical: 3),
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              color:
                                  _appleBlue(context).withValues(alpha: 0.15),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(Icons.add_rounded,
                                size: 22, color: _appleBlue(context)),
                          ),
                        ),
                      );
                    }
                    return const SizedBox.shrink();
                  }),
                  // Unified mic / send / stop button
                  Obx(() {
                    final loading = controller.isLoading.value;
                    final listening = controller.isListening.value;
                    final noModel = _localModelMissing();
                    final hasContent = controller.inputText.value.isNotEmpty ||
                        controller.selectedFileName.value != null ||
                        controller.selectedImagePath.value != null;

                    // Determine state
                    final Color bgColor;
                    final IconData iconData;
                    final VoidCallback? onTap;

                    if (loading) {
                      // AI generating → solid neutral stop
                      bgColor = isDark ? Colors.white : Colors.black;
                      iconData = Icons.stop_rounded;
                      onTap = controller.stopGenerating;
                    } else if (listening) {
                      // STT active → red stop
                      bgColor = const Color(0xFFFF3B30);
                      iconData = Icons.stop_rounded;
                      onTap = controller.toggleListening;
                    } else if (noModel) {
                      // Nothing to talk to: inert, faded mic
                      bgColor = Colors.transparent;
                      iconData = Icons.mic_none_rounded;
                      onTap = null;
                    } else if (hasContent) {
                      // Has text or attachment → blue send
                      bgColor = _appleBlue(context);
                      iconData = Icons.arrow_upward_rounded;
                      onTap = controller.sendMessage;
                    } else {
                      // Empty → bare mic glyph
                      bgColor = Colors.transparent;
                      iconData = Icons.mic_none_rounded;
                      onTap = controller.toggleListening;
                    }

                    final buttonTooltip = isDesktop
                        ? (loading
                            ? 'Stop generation'
                            : listening
                                ? 'Stop listening'
                                : noModel
                                    ? ''
                                    : hasContent
                                        ? 'Send (Enter · Shift+Enter for newline)'
                                        : 'Voice input')
                        : '';

                    final buttonContent = AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeInOut,
                      margin: const EdgeInsets.symmetric(vertical: 3),
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                          color: bgColor, shape: BoxShape.circle),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        transitionBuilder: (child, anim) =>
                            ScaleTransition(scale: anim, child: child),
                        child: Icon(iconData,
                            key: ValueKey(iconData),
                            color: loading
                                ? (isDark ? Colors.black : Colors.white)
                                : (listening || (hasContent && !noModel))
                                    ? Colors.white
                                    : Theme.of(context)
                                        .hintColor
                                        .withValues(alpha: noModel ? 0.4 : 1),
                            size: 20),
                      ),
                    );

                    return GestureDetector(
                      onTap: onTap,
                      child: buttonTooltip.isNotEmpty
                          ? Tooltip(
                              message: buttonTooltip,
                              waitDuration: const Duration(milliseconds: 400),
                              child: buttonContent,
                            )
                          : buttonContent,
                    );
                  }),
                ])),
            ]),
          ),
        ),
      ),
    ));
  }

  /// Local mode with no text or image model loaded (cloud never counts).
  bool _localModelMissing() {
    if (Get.find<SettingsController>().inferenceMode.value != 'local') {
      return false;
    }
    return !Get.find<InferenceService>().isModelLoaded.value &&
        !Get.find<LocalImageService>().isModelLoaded.value;
  }

  // ── Markdown styles ──
  MarkdownStyleSheet _streamMd(BuildContext c, bool isDark) =>
      ChatBubble.answerStyle(c);

  MarkdownStyleSheet _thoughtMd(BuildContext c, bool isDark) {
    final muted = Theme.of(c).hintColor;
    final base = GoogleFonts.inter(fontSize: 13, color: muted, height: 1.4);
    final codeBg = isDark ? const Color(0xFF2C2C2E) : const Color(0xFFE5E5EA);
    return MarkdownStyleSheet.fromTheme(Theme.of(c)).copyWith(
        p: base,
        strong: base.copyWith(fontWeight: FontWeight.w600),
        em: base.copyWith(fontStyle: FontStyle.italic),
        listBullet: base,
        code: GoogleFonts.firaCode(
            fontSize: 11, color: muted, backgroundColor: codeBg),
        codeblockDecoration: BoxDecoration(
            color: codeBg, borderRadius: BorderRadius.circular(10)));
  }

  // ── Helpers ──
  String _cleanStream(String t) => t
      .replaceAll(
          RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F]'), '')
      .replaceAll(RegExp(r'[\u200B-\u200D\uFEFF]'), '')
      .replaceAll('\uFFFD', '')
      .replaceAll('<|endoftext|>', '')
      .replaceAll('<|im_end|>', '')
      .replaceAll('<|end|>', '');

  bool _hasPrintable(String t) {
    for (final r in t.runes) {
      if (r > 32 &&
          r != 0x7F &&
          r != 0x200B &&
          r != 0x200C &&
          r != 0x200D &&
          r != 0xFEFF &&
          r != 0xFFFD) {
        return true;
      }
    }
    return false;
  }

  String _fmtK(int v) => v >= 1000000
      ? '${(v / 1000000).toStringAsFixed(1)}M'
      : v >= 1000
          ? '${(v / 1000).toStringAsFixed(1)}K'
          : v.toString();
}

// ── Attach Button ──
class _AttachButton extends StatelessWidget {
  final bool isDark;
  final bool isCloud;

  /// Photos/camera need a vision-capable model; documents work everywhere.
  final bool allowMedia;
  final VoidCallback onCamera;
  final VoidCallback onImage;
  final VoidCallback onFile;
  final BuildContext context;

  const _AttachButton({
    required this.isDark,
    required this.isCloud,
    required this.allowMedia,
    required this.onCamera,
    required this.onImage,
    required this.onFile,
    required this.context,
  });

  @override
  Widget build(BuildContext buildContext) {
    return Padding(
      padding: const EdgeInsets.only(right: 2),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _showMenu(buildContext),
        child: SizedBox(
          width: 36,
          height: 40,
          child: Icon(Icons.add_rounded,
              color: Theme.of(buildContext)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.7),
              size: 24),
        ),
      ),
    );
  }

  /// Popover anchored above the + button, growing out of it.
  void _showMenu(BuildContext ctx) {
    Haptics.selectionClick();
    FocusManager.instance.primaryFocus?.unfocus();
    final box = ctx.findRenderObject() as RenderBox;
    final origin = box.localToGlobal(Offset.zero);
    final screen = MediaQuery.of(ctx).size;
    final dark = Theme.of(ctx).brightness == Brightness.dark;

    final items = [
      (
        icon: Icons.photo_camera_outlined,
        label: 'Camera',
        enabled: allowMedia,
        onTap: onCamera,
      ),
      (
        icon: Icons.photo_outlined,
        label: 'Photos',
        enabled: allowMedia,
        onTap: onImage,
      ),
      (
        icon: Icons.attach_file_rounded,
        label: 'Files',
        enabled: true,
        onTap: onFile,
      ),
    ];

    showGeneralDialog(
      context: ctx,
      barrierDismissible: true,
      barrierLabel: 'Close',
      barrierColor: Colors.black.withValues(alpha: dark ? 0.35 : 0.12),
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (dialogCtx, _, __) {
        final fg = dark ? Colors.white : const Color(0xFF0B0B0C);
        final muted = dark ? const Color(0xFF8E8E93) : const Color(0xFF6E6E73);
        return Stack(children: [
          Positioned(
            left: origin.dx - 6,
            bottom: screen.height - origin.dy + 10,
            child: Material(
              color: Colors.transparent,
              child: Container(
                width: 236,
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: dark ? const Color(0xFF242427) : Colors.white,
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(
                      color: dark
                          ? Colors.white.withValues(alpha: 0.08)
                          : Colors.black.withValues(alpha: 0.06),
                      width: 0.5),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: dark ? 0.5 : 0.12),
                      blurRadius: 32,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  for (final it in items)
                    Opacity(
                      opacity: it.enabled ? 1 : 0.4,
                      child: InkWell(
                        onTap: it.enabled
                            ? () {
                                Navigator.pop(dialogCtx);
                                it.onTap();
                              }
                            : null,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          child: Row(children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: dark
                                    ? Colors.white.withValues(alpha: 0.08)
                                    : Colors.black.withValues(alpha: 0.05),
                              ),
                              child: Icon(it.icon, size: 21, color: fg),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(it.label,
                                        style: GoogleFonts.inter(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w500,
                                            letterSpacing: -0.2,
                                            color: fg)),
                                    if (!it.enabled)
                                      Text('Needs a vision model',
                                          style: GoogleFonts.inter(
                                              fontSize: 12, color: muted)),
                                  ]),
                            ),
                          ]),
                        ),
                      ),
                    ),
                ]),
              ),
            ),
          ),
        ]);
      },
      transitionBuilder: (_, anim, __, child) {
        final curved =
            CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween(begin: 0.92, end: 1.0).animate(curved),
            alignment: Alignment(-1 + 2 * (origin.dx / screen.width),
                -1 + 2 * (origin.dy / screen.height)),
            child: child,
          ),
        );
      },
    );
  }
}

class _PulsingDot extends StatefulWidget {
  const _PulsingDot();

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _c;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
    _scale = Tween<double>(begin: 0.7, end: 1.3)
        .animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _scale,
      child: Container(
        width: 8,
        height: 8,
        decoration: const BoxDecoration(
            color: Color(0xFFFF3B30), shape: BoxShape.circle),
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  const _StepButton({
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = enabled
        ? _appleBlue(context)
        : Theme.of(context).hintColor.withValues(alpha: 0.35);
    return GestureDetector(
      onTap: enabled ? onTap : null,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 30,
        height: 30,
        child: Icon(icon, size: 16, color: color),
      ),
    );
  }
}

// ── Image Generation Indicator ──
class _ImageGenIndicator extends StatefulWidget {
  final ChatController controller;
  final bool isDark;
  const _ImageGenIndicator({required this.controller, required this.isDark});

  @override
  State<_ImageGenIndicator> createState() => _ImageGenIndicatorState();
}

class _ImageGenIndicatorState extends State<_ImageGenIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _c;
  late Timer _timer;
  int _elapsedSeconds = 0;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final start = widget.controller.imageGenStartTime.value;
      if (start != null) {
        setState(() {
          _elapsedSeconds = DateTime.now().difference(start).inSeconds;
        });
      }
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    _c.dispose();
    super.dispose();
  }

  String _fmtEta(int seconds) {
    if (seconds <= 0) return '';
    if (seconds < 60) return '~$seconds s remaining';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return s > 0 ? '~$m m $s s remaining' : '~$m m remaining';
  }

  String _fmtElapsed(int seconds) {
    if (seconds < 60) return '${seconds}s';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return s > 0 ? '${m}m ${s}s' : '${m}m';
  }

  Widget _backendChip(BuildContext context) {
    final localImage = Get.find<LocalImageService>();
    final backend = localImage.currentBackend.value;
    final isCpu = backend == Backend.cpu;
    final color = isCpu
        ? const Color(0xFFFF9500) // Orange for CPU
        : const Color(0xFF34C759); // Green for GPU
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3), width: 0.5),
      ),
      child: Text(
        isCpu
            ? 'CPU · Slow'
            : backend == Backend.metal
                ? 'APPLE NPU'
                : backend.displayName.split(' ').first.toUpperCase(),
        style: GoogleFonts.inter(
          fontSize: 9,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) {
        final dots = Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final t = ((_c.value - i * 0.18) % 1.0).clamp(0.0, 1.0);
            final pulse = math.sin(t * math.pi).clamp(0.0, 1.0);
            return Padding(
              padding: EdgeInsets.only(right: i < 2 ? 5 : 0),
              child: Opacity(
                opacity: 0.25 + 0.75 * pulse,
                child: Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.isDark
                        ? Colors.white.withValues(alpha: 0.6)
                        : Colors.black.withValues(alpha: 0.35),
                  ),
                ),
              ),
            );
          }),
        );

        return Obx(() {
          final step = widget.controller.imageGenStep.value;
          final total = widget.controller.imageGenTotal.value;
          final eta = widget.controller.imageGenEstimatedSecs.value;
          final decoding = widget.controller.imageGenDecoding.value;
          final hasProgress = total > 0;
          final pct = hasProgress ? (step / total).clamp(0.0, 1.0) : 0.0;
          final isDone = decoding || (hasProgress && step >= total);

          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              dots,
              const SizedBox(height: 10),
              Text(
                isDone ? 'Decoding image' : 'Generating image',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  color: Theme.of(context).hintColor,
                  fontWeight: FontWeight.w400,
                ),
              ),
              if (hasProgress) ...[
                const SizedBox(height: 10),
                // Progress bar (pulse at 100% during decode)
                Container(
                  width: 160,
                  height: 4,
                  decoration: BoxDecoration(
                    color: (widget.isDark ? Colors.white : Colors.black)
                        .withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: isDone ? 1.0 : pct,
                    child: Container(
                      decoration: BoxDecoration(
                        color: _appleBlue(context),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                // Percentage + steps / decoding message
                Text(
                  isDone
                      ? 'VAE decode in progress…'
                      : '${(pct * 100).toStringAsFixed(0)}% · Step $step of $total',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: Theme.of(context).hintColor.withValues(alpha: 0.6),
                    fontWeight: FontWeight.w500,
                  ),
                ),
                // Backend badge
                const SizedBox(height: 5),
                _backendChip(context),
                // Elapsed time
                const SizedBox(height: 3),
                Text(
                  'Elapsed: ${_fmtElapsed(_elapsedSeconds)}',
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    color: Theme.of(context).hintColor.withValues(alpha: 0.45),
                  ),
                ),
                // ETA (only if we have a real estimate and not done)
                if (eta > 0 && step >= 2 && !isDone) ...[
                  const SizedBox(height: 3),
                  Text(
                    _fmtEta(eta),
                    style: GoogleFonts.inter(
                      fontSize: 10,
                      color:
                          Theme.of(context).hintColor.withValues(alpha: 0.45),
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                // Cancel button
                GestureDetector(
                  onTap: widget.controller.stopGenerating,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFF3B30).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.stop_rounded,
                            size: 12, color: Color(0xFFFF3B30)),
                        const SizedBox(width: 4),
                        Text(
                          'Cancel',
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            color: const Color(0xFFFF3B30),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          );
        });
      },
    );
  }
}

// ── Typing Dots ──
class _TypingDots extends StatefulWidget {
  final bool isDark;
  const _TypingDots({required this.isDark});
  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1400))
      ..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
        animation: _c,
        builder: (_, __) {
          return Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(3, (i) {
                final t = ((_c.value - i * 0.2) % 1.0).clamp(0.0, 1.0);
                final pulse = math.sin(t * math.pi).clamp(0.0, 1.0);
                return Padding(
                    padding: EdgeInsets.only(right: i < 2 ? 5 : 0),
                    child: Opacity(
                        opacity: 0.25 + 0.75 * pulse,
                        child: Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: widget.isDark
                                    ? Colors.white.withValues(alpha: 0.6)
                                    : Colors.black.withValues(alpha: 0.35)))));
              }));
        });
  }
}

// ── Blinking Cursor ──
class _BlinkingCursor extends StatefulWidget {
  final Color color;
  const _BlinkingCursor({required this.color});
  @override
  State<_BlinkingCursor> createState() => _BlinkingCursorState();
}

class _BlinkingCursorState extends State<_BlinkingCursor>
    with SingleTickerProviderStateMixin {
  late AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 600))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
        animation: _c,
        builder: (_, __) => Opacity(
            opacity: _c.value,
            child: Container(
                width: 2,
                height: 16,
                margin: const EdgeInsets.only(left: 2, bottom: 2),
                decoration: BoxDecoration(
                    color: widget.color,
                    borderRadius: BorderRadius.circular(1)))));
  }
}

class _ClusterFallbackButton extends StatefulWidget {
  final ClusterService cluster;
  final bool isDark;

  const _ClusterFallbackButton({required this.cluster, required this.isDark});

  @override
  State<_ClusterFallbackButton> createState() => _ClusterFallbackButtonState();
}

class _ClusterFallbackButtonState extends State<_ClusterFallbackButton> {
  bool _isLoading = false;

  Future<void> _handleFallback() async {
    if (_isLoading) return;
    setState(() => _isLoading = true);
    Haptics.mediumImpact();
    final ok = await widget.cluster.fallbackToLocal();
    if (mounted) {
      setState(() => _isLoading = false);
      if (ok) {
        showToast('Cluster Recovered', 'Switched to local execution on master.',
            tone: ToastTone.success);
      } else {
        showToast('Fallback failed', 'Could not reload model locally.',
            tone: ToastTone.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFFF9500)
          .withValues(alpha: widget.isDark ? 0.22 : 0.15),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: _isLoading ? null : _handleFallback,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_isLoading) ...[
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xFFFF9500),
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Text(
                'Fallback to Local',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: const Color(0xFFFF9500),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RetestPingsButton extends StatefulWidget {
  final ClusterService cluster;
  final bool isDark;

  const _RetestPingsButton({required this.cluster, required this.isDark});

  @override
  State<_RetestPingsButton> createState() => _RetestPingsButtonState();
}

class _RetestPingsButtonState extends State<_RetestPingsButton> {
  bool _isTesting = false;

  Future<void> _handleRetest() async {
    if (_isTesting) return;
    setState(() => _isTesting = true);
    Haptics.selectionClick();
    await widget.cluster.retestPings();
    if (mounted) setState(() => _isTesting = false);
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: widget.isDark
          ? Colors.white.withValues(alpha: 0.08)
          : Colors.black.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: _isTesting ? null : _handleRetest,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedRotation(
                turns: _isTesting ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 600),
                child: Icon(
                  Icons.refresh_rounded,
                  size: 15,
                  color: Theme.of(context).hintColor,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                'Re-test Pings',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: widget.isDark ? Colors.white : const Color(0xFF0B0B0C),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
