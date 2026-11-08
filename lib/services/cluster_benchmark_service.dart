import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, Socket;

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:get/get.dart';
import 'package:http/http.dart' as http;

import 'cluster_service.dart';
import 'desktop_inference_engine.dart';
import 'hive_service.dart';
import 'inference_service.dart';

/// Result of a single standardized inference benchmark execution.
class BenchmarkResult {
  /// Whether this benchmark was executed in distributed LAN cluster mode.
  final bool isCluster;

  /// Standardized prompt token count evaluated in prefill.
  final int promptTokens;

  /// Actual tokens generated in the evaluation stream.
  final int evalTokens;

  /// Time to First Token (TTFT) in milliseconds from dispatch to first stream event.
  final double ttftMs;

  /// Prompt processing throughput in tokens per second.
  final double promptTokensPerSecond;

  /// Token-by-token generation throughput in tokens per second.
  final double evalTokensPerSecond;

  /// Estimated or measured round-trip network overhead in milliseconds.
  final double networkOverheadMs;

  /// Wall-clock timestamp when the benchmark was completed.
  final DateTime timestamp;

  /// Total duration of the benchmark run in milliseconds.
  final double totalTimeMs;

  /// Name of the model evaluated during the benchmark.
  final String modelName;

  /// Inter-token generation arrival latencies in milliseconds.
  final List<double> interTokenLatenciesMs;

  const BenchmarkResult({
    required this.isCluster,
    required this.promptTokens,
    required this.evalTokens,
    required this.ttftMs,
    required this.promptTokensPerSecond,
    required this.evalTokensPerSecond,
    required this.networkOverheadMs,
    required this.timestamp,
    this.totalTimeMs = 0.0,
    this.modelName = '',
    this.interTokenLatenciesMs = const [],
  });

  /// Formatted generation throughput string (e.g. "18.42 tps").
  String get evalTpsFormatted => '${evalTokensPerSecond.toStringAsFixed(2)} tps';

  /// Formatted prompt prefill throughput string (e.g. "142.10 tps").
  String get promptTpsFormatted => '${promptTokensPerSecond.toStringAsFixed(2)} tps';

  /// Formatted Time to First Token string (e.g. "214.5 ms").
  String get ttftFormatted => '${ttftMs.toStringAsFixed(1)} ms';

  /// Formatted network overhead string (e.g. "3.8 ms").
  String get networkOverheadFormatted => '${networkOverheadMs.toStringAsFixed(1)} ms';

  Map<String, dynamic> toMap() => {
        'isCluster': isCluster,
        'promptTokens': promptTokens,
        'evalTokens': evalTokens,
        'ttftMs': ttftMs,
        'promptTokensPerSecond': promptTokensPerSecond,
        'evalTokensPerSecond': evalTokensPerSecond,
        'networkOverheadMs': networkOverheadMs,
        'timestamp': timestamp.toIso8601String(),
        'totalTimeMs': totalTimeMs,
        'modelName': modelName,
        'interTokenLatenciesMs': interTokenLatenciesMs,
      };

  factory BenchmarkResult.fromMap(Map<String, dynamic> map) => BenchmarkResult(
        isCluster: map['isCluster'] as bool? ?? false,
        promptTokens: map['promptTokens'] as int? ?? 0,
        evalTokens: map['evalTokens'] as int? ?? 0,
        ttftMs: (map['ttftMs'] as num?)?.toDouble() ?? 0.0,
        promptTokensPerSecond: (map['promptTokensPerSecond'] as num?)?.toDouble() ?? 0.0,
        evalTokensPerSecond: (map['evalTokensPerSecond'] as num?)?.toDouble() ?? 0.0,
        networkOverheadMs: (map['networkOverheadMs'] as num?)?.toDouble() ?? 0.0,
        timestamp: map['timestamp'] != null
            ? DateTime.tryParse(map['timestamp'].toString()) ?? DateTime.now()
            : DateTime.now(),
        totalTimeMs: (map['totalTimeMs'] as num?)?.toDouble() ?? 0.0,
        modelName: map['modelName'] as String? ?? '',
        interTokenLatenciesMs: (map['interTokenLatenciesMs'] as List?)
                ?.map((e) => (e as num).toDouble())
                .toList() ??
            const [],
      );

  String toJson() => jsonEncode(toMap());

  factory BenchmarkResult.fromJson(String source) =>
      BenchmarkResult.fromMap(jsonDecode(source) as Map<String, dynamic>);
}

/// Pairs local single-device benchmark results with distributed cluster results,
/// computing speedup percentages, throughput multipliers, and memory savings.
class BenchmarkComparison {
  /// Result from the single-device local inference engine test.
  final BenchmarkResult? localResult;

  /// Result from the multi-node distributed cluster inference test.
  final BenchmarkResult? clusterResult;

  /// Local memory footprint retained on master device (in MB).
  final double? masterMemoryMb;

  /// Total tensor memory offloaded across remote LAN worker nodes (in MB).
  final double? offloadedMemoryMb;

  /// When this comparison was formulated.
  final DateTime timestamp;

  const BenchmarkComparison({
    this.localResult,
    this.clusterResult,
    this.masterMemoryMb,
    this.offloadedMemoryMb,
    required this.timestamp,
  });

  /// Generation throughput speedup percentage:
  /// `((cluster - local) / local) * 100.0`
  /// Positive indicates cluster is faster; negative indicates local was faster.
  double? get speedupPercentage {
    if (localResult == null || clusterResult == null) return null;
    if (localResult!.evalTokensPerSecond <= 0) return null;
    return ((clusterResult!.evalTokensPerSecond - localResult!.evalTokensPerSecond) /
            localResult!.evalTokensPerSecond) *
        100.0;
  }

  /// Throughput multiplier factor (e.g. 1.45x).
  double? get speedupFactor {
    if (localResult == null || clusterResult == null) return null;
    if (localResult!.evalTokensPerSecond <= 0) return null;
    return clusterResult!.evalTokensPerSecond / localResult!.evalTokensPerSecond;
  }

  /// Prompt prefill processing speedup percentage:
  double? get promptSpeedupPercentage {
    if (localResult == null || clusterResult == null) return null;
    if (localResult!.promptTokensPerSecond <= 0) return null;
    return ((clusterResult!.promptTokensPerSecond - localResult!.promptTokensPerSecond) /
            localResult!.promptTokensPerSecond) *
        100.0;
  }

  /// Time to First Token delta (in ms): `cluster.ttftMs - local.ttftMs`.
  /// Positive means cluster incurred higher initial latency (due to LAN dispatch).
  double? get ttftDeltaMs {
    if (localResult == null || clusterResult == null) return null;
    return clusterResult!.ttftMs - localResult!.ttftMs;
  }

  /// Memory offloaded to remote LAN cluster nodes in MB.
  double? get memorySavingsMb => offloadedMemoryMb;

  /// Percentage of total model parameters offloaded away from the master device:
  /// `(offloaded / (master + offloaded)) * 100.0`
  double? get memorySavingsPercentage {
    if (masterMemoryMb == null || offloadedMemoryMb == null) return null;
    final total = masterMemoryMb! + offloadedMemoryMb!;
    if (total <= 0) return null;
    return (offloadedMemoryMb! / total) * 100.0;
  }

  /// True if both local and cluster benchmarks are available.
  bool get hasBoth => localResult != null && clusterResult != null;

  /// True if cluster generation throughput exceeds local throughput.
  bool get isClusterFaster => (speedupPercentage ?? 0) > 0;

  /// Formatted speedup badge text (e.g. "+34.5%" or "-12.0%").
  String get speedupFormatted {
    final pct = speedupPercentage;
    if (pct == null) return 'N/A';
    final sign = pct >= 0 ? '+' : '';
    return '$sign${pct.toStringAsFixed(1)}%';
  }

  /// Formatted memory savings string (e.g. "2.40 GB (52.3%)").
  String get memorySavingsFormatted {
    final mb = memorySavingsMb;
    final pct = memorySavingsPercentage;
    if (mb == null || mb <= 0) return '0 MB (0%)';
    if (mb >= 1024) {
      return '${(mb / 1024).toStringAsFixed(2)} GB (${pct?.toStringAsFixed(1) ?? "0"}%)';
    }
    return '${mb.toStringAsFixed(0)} MB (${pct?.toStringAsFixed(1) ?? "0"}%)';
  }

  Map<String, dynamic> toMap() => {
        'localResult': localResult?.toMap(),
        'clusterResult': clusterResult?.toMap(),
        'masterMemoryMb': masterMemoryMb,
        'offloadedMemoryMb': offloadedMemoryMb,
        'timestamp': timestamp.toIso8601String(),
      };

  factory BenchmarkComparison.fromMap(Map<String, dynamic> map) => BenchmarkComparison(
        localResult: map['localResult'] != null
            ? BenchmarkResult.fromMap(map['localResult'] as Map<String, dynamic>)
            : null,
        clusterResult: map['clusterResult'] != null
            ? BenchmarkResult.fromMap(map['clusterResult'] as Map<String, dynamic>)
            : null,
        masterMemoryMb: (map['masterMemoryMb'] as num?)?.toDouble(),
        offloadedMemoryMb: (map['offloadedMemoryMb'] as num?)?.toDouble(),
        timestamp: map['timestamp'] != null
            ? DateTime.tryParse(map['timestamp'].toString()) ?? DateTime.now()
            : DateTime.now(),
      );

  String toJson() => jsonEncode(toMap());

  factory BenchmarkComparison.fromJson(String source) =>
      BenchmarkComparison.fromMap(jsonDecode(source) as Map<String, dynamic>);
}

/// Distributed Cluster Benchmark Service for PrivateLM.
///
/// Executes standardized 64-token synthetic inference prompts against active
/// inference engines, recording high-precision microsecond timestamps for:
/// 1. Dispatch to first token stream event (TTFT).
/// 2. Prompt processing completion.
/// 3. Token-by-token generation throughput.
///
/// Exposes reactive GetX states and comparison metrics between local and cluster inference.
class ClusterBenchmarkService extends GetxService {
  /// Standardized benchmark token count for reproducible testing.
  static const int standardizedTargetTokens = 64;

  /// Estimated prompt token count for the standardized synthetic prompt.
  static const int standardizedPromptTokens = 64;

  /// Standardized synthetic prompt designed to stress tensor operations and pipeline latency.
  static const String standardizedSyntheticPrompt =
      'Benchmark prompt for distributed tensor parallelism evaluation. '
      'In heterogeneous local area network clusters, pipeline parallelism splits model transformer layers across worker devices. '
      'Analyze the computational trade-offs between memory bandwidth, interconnect latency, quantization precision, tensor cache synchronization overhead, and network throughput under high-concurrency inference workloads.';

  static const String _keyLocalResult = 'cluster_benchmark_local_result';
  static const String _keyClusterResult = 'cluster_benchmark_cluster_result';

  static ClusterBenchmarkService get to => Get.find<ClusterBenchmarkService>();

  // ── Reactive GetX States ──
  final isBenchmarking = false.obs;
  final Rx<BenchmarkComparison?> latestComparison = Rx<BenchmarkComparison?>(null);
  final Rx<BenchmarkResult?> latestLocalResult = Rx<BenchmarkResult?>(null);
  final Rx<BenchmarkResult?> latestClusterResult = Rx<BenchmarkResult?>(null);

  final currentProgress = 0.0.obs;
  final statusMessage = ''.obs;
  final streamedTestTokens = 0.obs;
  final currentTps = 0.0.obs;

  http.Client? _activeHttpClient;
  bool _isCancelled = false;

  @override
  void onInit() {
    super.onInit();
    _restoreSavedResults();
  }

  @override
  void onClose() {
    _activeHttpClient?.close();
    super.onClose();
  }

  /// Restores cached benchmark results from persistent storage.
  void _restoreSavedResults() {
    try {
      if (!Get.isRegistered<HiveService>()) return;
      final hive = Get.find<HiveService>();
      final localMap = hive.getSetting<Map>(_keyLocalResult);
      if (localMap != null) {
        latestLocalResult.value =
            BenchmarkResult.fromMap(Map<String, dynamic>.from(localMap));
      }
      final clusterMap = hive.getSetting<Map>(_keyClusterResult);
      if (clusterMap != null) {
        latestClusterResult.value =
            BenchmarkResult.fromMap(Map<String, dynamic>.from(clusterMap));
      }
      _updateComparison();
    } catch (e) {
      debugPrint('[ClusterBenchmark] Error restoring saved results: $e');
    }
  }

  /// Persists current benchmark results to Hive storage.
  void _persistBenchmarkData() {
    try {
      if (!Get.isRegistered<HiveService>()) return;
      final hive = Get.find<HiveService>();
      if (latestLocalResult.value != null) {
        hive.setSetting(_keyLocalResult, latestLocalResult.value!.toMap());
      }
      if (latestClusterResult.value != null) {
        hive.setSetting(_keyClusterResult, latestClusterResult.value!.toMap());
      }
    } catch (e) {
      debugPrint('[ClusterBenchmark] Error persisting results: $e');
    }
  }

  /// Updates the paired [latestComparison] reactive state.
  void _updateComparison({double? masterMemMb, double? offloadedMemMb}) {
    if (latestLocalResult.value == null && latestClusterResult.value == null) {
      latestComparison.value = null;
      return;
    }

    double? effectiveMasterMem = masterMemMb;
    double? effectiveOffloadedMem = offloadedMemMb;

    if (Get.isRegistered<ClusterService>()) {
      final cs = Get.find<ClusterService>();
      if (cs.split.isNotEmpty) {
        effectiveMasterMem ??=
            cs.split.where((s) => s.isThisPhone).fold<double>(0.0, (a, s) => a + s.mb);
        effectiveOffloadedMem ??=
            cs.split.where((s) => !s.isThisPhone).fold<double>(0.0, (a, s) => a + s.mb);
      } else if (cs.workers.isNotEmpty) {
        effectiveOffloadedMem ??=
            cs.workers.fold<double>(0.0, (a, w) => a + (w.ramMb ?? 0.0));
      }
    }

    latestComparison.value = BenchmarkComparison(
      localResult: latestLocalResult.value,
      clusterResult: latestClusterResult.value,
      masterMemoryMb: effectiveMasterMem,
      offloadedMemoryMb: effectiveOffloadedMem,
      timestamp: DateTime.now(),
    );
  }

  /// Manually records a local benchmark result and updates comparison state.
  void recordLocalResult(BenchmarkResult result) {
    latestLocalResult.value = result;
    _updateComparison();
    _persistBenchmarkData();
  }

  /// Manually records a cluster benchmark result and updates comparison state.
  void recordClusterResult(BenchmarkResult result) {
    latestClusterResult.value = result;
    _updateComparison();
    _persistBenchmarkData();
  }

  /// Clears active benchmark results from memory and storage.
  void clearBenchmark() {
    latestLocalResult.value = null;
    latestClusterResult.value = null;
    latestComparison.value = null;
    currentProgress.value = 0.0;
    streamedTestTokens.value = 0;
    currentTps.value = 0.0;
    statusMessage.value = '';
    try {
      if (Get.isRegistered<HiveService>()) {
        final hive = Get.find<HiveService>();
        hive.setSetting(_keyLocalResult, null);
        hive.setSetting(_keyClusterResult, null);
      }
    } catch (_) {}
  }

  /// Cancels an in-flight benchmark run.
  Future<void> cancelBenchmark() async {
    _isCancelled = true;
    _activeHttpClient?.close();
    _activeHttpClient = null;

    if (Get.isRegistered<InferenceService>()) {
      try {
        await Get.find<InferenceService>().stopGeneration();
      } catch (_) {}
    }

    isBenchmarking.value = false;
    statusMessage.value = 'Benchmark cancelled';
  }

  /// Executes the standardized 64-token synthetic prompt test.
  ///
  /// Parameters:
  /// - [isCluster]: Overrides cluster detection. If null, automatically infers from [ClusterService].
  /// - [targetTokens]: Generation token limit (defaults to 64).
  /// - [prompt]: Synthetic prompt string (defaults to [standardizedSyntheticPrompt]).
  /// - [desktopEngine]: Optional explicit [DesktopInferenceEngine] instance.
  /// - [engine]: Optional explicit [InferenceEngine] instance.
  /// - [modelName]: Model identifier for logging and reporting.
  /// - [updateLatest]: When true, updates [latestLocalResult], [latestClusterResult], and [latestComparison].
  Future<BenchmarkResult> runBenchmark({
    bool? isCluster,
    int targetTokens = standardizedTargetTokens,
    String? prompt,
    DesktopInferenceEngine? desktopEngine,
    dynamic engine,
    String? modelName,
    bool updateLatest = true,
  }) async {
    if (isBenchmarking.value) {
      throw StateError('A benchmark is already in progress');
    }

    _isCancelled = false;
    isBenchmarking.value = true;
    currentProgress.value = 0.0;
    streamedTestTokens.value = 0;
    currentTps.value = 0.0;
    statusMessage.value = 'Preparing benchmark...';

    DesktopInferenceEngine? effectiveDesktopEngine = desktopEngine;
    dynamic effectiveEngine = engine;

    if (effectiveDesktopEngine == null && effectiveEngine == null) {
      if (Get.isRegistered<InferenceService>()) {
        final inf = Get.find<InferenceService>();
        if (!inf.isModelLoaded.value && inf.activeEngine == null) {
          isBenchmarking.value = false;
          statusMessage.value = 'No model loaded';
          throw StateError('No model is currently loaded in InferenceService');
        }
        effectiveEngine = inf.activeEngine;
        modelName ??= inf.loadedModelName.value;
      }
    }

    // Inspect if InferenceEngine wraps an active DesktopInferenceEngine
    if (effectiveDesktopEngine == null && effectiveEngine != null) {
      try {
        final de = (effectiveEngine as dynamic).desktopEngine;
        if (de is DesktopInferenceEngine && de.isModelLoaded) {
          effectiveDesktopEngine = de;
        }
      } catch (_) {}
    }

    // Determine cluster execution context
    bool effectiveIsCluster = isCluster ?? false;
    double measuredNetworkOverheadMs = 0.0;
    double? masterMemMb;
    double? offloadedMemMb;

    if (Get.isRegistered<ClusterService>()) {
      final cs = Get.find<ClusterService>();
      if (isCluster == null) {
        effectiveIsCluster = (cs.enabled.value && cs.workers.isNotEmpty) ||
            cs.split.where((s) => !s.isThisPhone).isNotEmpty;
      }

      if (effectiveIsCluster) {
        measuredNetworkOverheadMs = cs.clusterLatencyMs.value.toDouble();
        if (measuredNetworkOverheadMs <= 0 && cs.workers.isNotEmpty) {
          measuredNetworkOverheadMs = await _measureClusterPing(cs);
        }

        if (cs.split.isNotEmpty) {
          masterMemMb =
              cs.split.where((s) => s.isThisPhone).fold<double>(0.0, (a, s) => a + s.mb);
          offloadedMemMb =
              cs.split.where((s) => !s.isThisPhone).fold<double>(0.0, (a, s) => a + s.mb);
        } else if (cs.workers.isNotEmpty) {
          offloadedMemMb =
              cs.workers.fold<double>(0.0, (a, w) => a + (w.ramMb ?? 0.0));
        }
      }
    }

    final effectivePrompt = prompt ?? standardizedSyntheticPrompt;
    int measuredPromptTokens = standardizedPromptTokens;

    // Retrieve exact token count from llama-server if available
    if (effectiveDesktopEngine != null && effectiveDesktopEngine.isModelLoaded) {
      try {
        final tokenRes = await _queryExactTokenCount(
          effectiveDesktopEngine.port,
          effectivePrompt,
        );
        if (tokenRes > 0) measuredPromptTokens = tokenRes;
      } catch (_) {}
    }

    statusMessage.value = effectiveIsCluster
        ? 'Measuring cluster inference ($targetTokens tokens)...'
        : 'Measuring local inference ($targetTokens tokens)...';

    final stopwatch = Stopwatch()..start();
    final int dispatchMicros = stopwatch.elapsedMicroseconds;

    int? firstTokenMicros;
    int lastTokenMicros = dispatchMicros;
    int evalTokens = 0;
    final interTokenLatencies = <double>[];
    final buffer = StringBuffer();

    void onTokenReceived(String token) {
      if (_isCancelled) return;
      final int now = stopwatch.elapsedMicroseconds;
      if (firstTokenMicros == null) {
        firstTokenMicros = now;
        lastTokenMicros = now;
      } else {
        final deltaMs = (now - lastTokenMicros) / 1000.0;
        interTokenLatencies.add(deltaMs);
        lastTokenMicros = now;
      }

      evalTokens++;
      buffer.write(token);
      streamedTestTokens.value = evalTokens;
      currentProgress.value = (evalTokens / targetTokens).clamp(0.0, 1.0);

      final currentElapsedSec = (now - firstTokenMicros!) / 1000000.0;
      if (currentElapsedSec > 0) {
        currentTps.value = evalTokens / currentElapsedSec;
      }
    }

    try {
      if (effectiveDesktopEngine != null && effectiveDesktopEngine.isModelLoaded) {
        await _streamDesktopHttp(
          port: effectiveDesktopEngine.port,
          prompt: effectivePrompt,
          maxTokens: targetTokens,
          onToken: onTokenReceived,
        );
      } else if (effectiveEngine != null) {
        await effectiveEngine.generate(
          prompt: effectivePrompt,
          systemPrompt: '',
          modelName: modelName ?? 'local',
          maxTokens: targetTokens,
          temperature: 0.0,
          source: 'benchmark',
          onToken: onTokenReceived,
        );
      } else {
        throw StateError('No active inference engine found');
      }
    } catch (e) {
      if (!_isCancelled) {
        isBenchmarking.value = false;
        statusMessage.value = 'Benchmark failed: $e';
        rethrow;
      }
    }

    final int endMicros = stopwatch.elapsedMicroseconds;
    stopwatch.stop();

    if (_isCancelled) {
      isBenchmarking.value = false;
      statusMessage.value = 'Benchmark cancelled';
      throw StateError('Benchmark was cancelled');
    }

    // 1. Dispatch to first token stream event (TTFT)
    final double ttftMs = firstTokenMicros != null
        ? (firstTokenMicros! - dispatchMicros) / 1000.0
        : (endMicros - dispatchMicros) / 1000.0;

    // 2. Prompt processing completion throughput
    final double promptDurationSec = ttftMs / 1000.0;
    final double promptTokensPerSecond = promptDurationSec > 0
        ? (measuredPromptTokens / promptDurationSec)
        : 0.0;

    // 3. Token-by-token generation throughput
    final double evalDurationSec = firstTokenMicros != null
        ? (endMicros - firstTokenMicros!) / 1000000.0
        : (endMicros - dispatchMicros) / 1000000.0;

    final double evalTokensPerSecond = evalDurationSec > 0
        ? (evalTokens / evalDurationSec)
        : (evalTokens > 0
            ? (evalTokens / (promptDurationSec > 0 ? promptDurationSec : 0.001))
            : 0.0);

    final double totalTimeMs = (endMicros - dispatchMicros) / 1000.0;

    final result = BenchmarkResult(
      isCluster: effectiveIsCluster,
      promptTokens: measuredPromptTokens,
      evalTokens: evalTokens,
      ttftMs: ttftMs,
      promptTokensPerSecond: promptTokensPerSecond,
      evalTokensPerSecond: evalTokensPerSecond,
      networkOverheadMs: measuredNetworkOverheadMs,
      timestamp: DateTime.now(),
      totalTimeMs: totalTimeMs,
      modelName: modelName ?? '',
      interTokenLatenciesMs: interTokenLatencies,
    );

    if (updateLatest) {
      if (result.isCluster) {
        latestClusterResult.value = result;
      } else {
        latestLocalResult.value = result;
      }
      _updateComparison(masterMemMb: masterMemMb, offloadedMemMb: offloadedMemMb);
      _persistBenchmarkData();
    }

    currentProgress.value = 1.0;
    isBenchmarking.value = false;
    statusMessage.value =
        'Benchmark complete (${evalTokensPerSecond.toStringAsFixed(1)} tps)';

    return result;
  }

  /// High-performance SSE HTTP streaming directly against llama-server.
  Future<void> _streamDesktopHttp({
    required int port,
    required String prompt,
    required int maxTokens,
    required void Function(String token) onToken,
  }) async {
    _activeHttpClient = http.Client();
    final request = http.Request(
      'POST',
      Uri.parse('http://127.0.0.1:$port/v1/chat/completions'),
    )
      ..headers['Content-Type'] = 'application/json'
      ..headers['Accept'] = 'text/event-stream'
      ..body = jsonEncode({
        'model': 'local',
        'messages': [
          {'role': 'user', 'content': prompt},
        ],
        'temperature': 0.0,
        'max_tokens': maxTokens,
        'stream': true,
      });

    final response = await _activeHttpClient!.send(request);
    if (response.statusCode != 200) {
      final err = await response.stream.bytesToString();
      throw Exception('llama-server returned HTTP ${response.statusCode}: $err');
    }

    final completer = Completer<void>();
    response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
      (line) {
        if (_isCancelled) {
          if (!completer.isCompleted) completer.complete();
          return;
        }
        final trimmed = line.trim();
        if (trimmed.isEmpty || !trimmed.startsWith('data:')) return;
        final jsonStr = trimmed.substring(5).trim();
        if (jsonStr == '[DONE]') {
          if (!completer.isCompleted) completer.complete();
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
              onToken(content);
            }
          }
        } catch (_) {}
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
      onError: (err) {
        if (!completer.isCompleted) completer.completeError(err);
      },
      cancelOnError: true,
    );

    await completer.future;
    _activeHttpClient?.close();
    _activeHttpClient = null;
  }

  /// Queries exact tokenization from the running llama-server `/tokenize` endpoint.
  Future<int> _queryExactTokenCount(int port, String text) async {
    final client = http.Client();
    try {
      final res = await client
          .post(
            Uri.parse('http://127.0.0.1:$port/tokenize'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'content': text}),
          )
          .timeout(const Duration(milliseconds: 600));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final tokens = data['tokens'] as List?;
        if (tokens != null) return tokens.length;
      }
    } catch (_) {} finally {
      client.close();
    }
    return 0;
  }

  /// Measures live socket ping to active cluster worker nodes.
  Future<double> _measureClusterPing(ClusterService cs) async {
    final pings = <int>[];
    for (final worker in cs.workers) {
      final parts = worker.endpoint.split(':');
      if (parts.isEmpty) continue;
      final host = parts[0];
      final port = parts.length > 1 ? int.tryParse(parts[1]) ?? 50052 : 50052;
      final ms = await cs.pingWorker(host, port, timeout: const Duration(milliseconds: 600));
      if (ms != null) pings.add(ms);
    }
    if (pings.isNotEmpty) {
      return pings.reduce((a, b) => a + b) / pings.length;
    }
    return 0.0;
  }
}
