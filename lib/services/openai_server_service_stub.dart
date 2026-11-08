import 'dart:async';

class OpenAiServerService {
  bool get isRunning => false;
  int? get port => null;
  String? get apiKey => null;
  String? get host => null;
  String? get localUrl => null;

  static Future<String?> getReachableIpv4Address() async => null;

  Future<void> start({
    int port = 8080,
    String? apiKey,
    bool allowNetwork = false,
    void Function(String)? onLog,
  }) async {
    throw UnsupportedError('Local API server is not available on this platform.');
  }

  void updateApiKey(String? apiKey) {}

  Future<void> stop() async {}
}
