import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:privatelm/core/constants.dart';
import 'package:privatelm/controllers/model_controller.dart';
import 'package:privatelm/controllers/settings_controller.dart';
import 'package:privatelm/services/app_log_service.dart';
import 'package:privatelm/services/download_service.dart';
import 'package:privatelm/services/hive_service.dart';
import 'package:privatelm/services/inference_service.dart';
import 'package:privatelm/services/local_image_service.dart';

class FakeDownloadService extends DownloadService {
  final String baseDir;
  FakeDownloadService(this.baseDir);

  @override
  Future<String> get modelsDir async => p.join(baseDir, 'app_models');

  @override
  Future<String> modelPath(String filename) async =>
      p.join(baseDir, 'app_models', filename);

  @override
  Future<List<String>> getDownloadedModels() async => [];

  @override
  Future<int> getModelSize(String filename) async => 0;

  @override
  Future<void> deleteModel(String filename) async {
    final file = File(p.join(baseDir, 'app_models', filename));
    if (file.existsSync()) {
      file.deleteSync();
    }
  }
}

class FakeInferenceService extends InferenceService {
  @override
  Future<void> unloadModel() async {}
}

class FakeLocalImageService extends LocalImageService {
  @override
  Future<void> unloadModel() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late HiveService hiveService;
  late ModelController modelController;
  late FakeDownloadService downloadService;

  setUp(() async {
    Get.reset();
    tempDir = await Directory.systemTemp.createTemp('desktop_storage_test_');
    Hive.init(p.join(tempDir.path, 'hive'));

    hiveService = HiveService();
    await hiveService.init();
    Get.put<HiveService>(hiveService);
    Get.put<AppLogService>(AppLogService());
    Get.put<SettingsController>(SettingsController());
    Get.put<InferenceService>(FakeInferenceService());
    Get.put<LocalImageService>(FakeLocalImageService());

    downloadService = FakeDownloadService(tempDir.path);
    Get.put<DownloadService>(downloadService);

    modelController = Get.put<ModelController>(ModelController());
  });

  tearDown(() async {
    Get.reset();
    await Hive.deleteFromDisk();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Desktop Model Storage & Zero-Copy Linking Tests', () {
    test('Desktop environment flag correctly identifies desktop platform', () {
      final isExpectedDesktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;
      expect(ModelController.isDesktop, equals(isExpectedDesktop));
    });

    test('modelPath resolution returns external path when file exists, fallback when missing', () async {
      final externalDir = Directory(p.join(tempDir.path, 'external_models'));
      await externalDir.create(recursive: true);

      final externalFile = File(p.join(externalDir.path, 'qwen2.5-7b.gguf'));
      await externalFile.writeAsBytes(List.filled(1024, 42));

      // 1. Unregistered file resolves to default app storage path
      final fallbackDefault = await modelController.modelPath('unregistered.gguf');
      expect(fallbackDefault, equals(p.join(tempDir.path, 'app_models', 'unregistered.gguf')));

      // 2. Registered external model with existing file returns external path
      modelController.externalModelPaths['qwen2.5-7b.gguf'] = externalFile.path;
      expect(modelController.isModelLinked('qwen2.5-7b.gguf'), isTrue);
      expect(modelController.getExternalPath('qwen2.5-7b.gguf'), equals(externalFile.path));

      final resolvedPath = await modelController.modelPath('qwen2.5-7b.gguf');
      expect(resolvedPath, equals(externalFile.path));

      // 3. If external file is removed from disk, falls back to default app models path
      await externalFile.delete();
      expect(externalFile.existsSync(), isFalse);

      final fallbackAfterDelete = await modelController.modelPath('qwen2.5-7b.gguf');
      expect(fallbackAfterDelete, equals(p.join(tempDir.path, 'app_models', 'qwen2.5-7b.gguf')));
    });

    test('Scan custom model folder finds and links *.gguf files, persists directory in Hive', () async {
      final scanDir = Directory(p.join(tempDir.path, 'custom_models_vault'));
      await scanDir.create(recursive: true);

      // Create dummy GGUF models and non-GGUF file
      final model1 = File(p.join(scanDir.path, 'mistral-7b-instruct.Q4_K_M.gguf'));
      final model2 = File(p.join(scanDir.path, 'deepseek-coder-6.7b.gguf'));
      final nonModel = File(p.join(scanDir.path, 'readme.txt'));

      await model1.writeAsBytes(List.filled(2048, 1));
      await model2.writeAsBytes(List.filled(4096, 2));
      await nonModel.writeAsString('not a model');

      await modelController.scanCustomModelFolder(directoryPath: scanDir.path);

      // Verify custom_models_directory persistence
      expect(modelController.customModelsDirectory, equals(scanDir.path));
      expect(hiveService.getSetting<String>(AppConstants.keyCustomModelsDirectory), equals(scanDir.path));

      // Verify both GGUF models are registered in externalModelPaths
      expect(modelController.externalModelPaths.containsKey('mistral-7b-instruct.Q4_K_M.gguf'), isTrue);
      expect(modelController.externalModelPaths.containsKey('deepseek-coder-6.7b.gguf'), isTrue);
      expect(modelController.externalModelPaths.containsKey('readme.txt'), isFalse);

      // Verify models are in availableModels with isImported: true
      final registered1 = modelController.availableModels
          .firstWhereOrNull((m) => m.filename == 'mistral-7b-instruct.Q4_K_M.gguf');
      expect(registered1, isNotNull);
      expect(registered1!.isImported, isTrue);
      expect(registered1.runtime, equals('llama'));

      final registered2 = modelController.availableModels
          .firstWhereOrNull((m) => m.filename == 'deepseek-coder-6.7b.gguf');
      expect(registered2, isNotNull);
      expect(registered2!.isImported, isTrue);

      // Verify isDownloaded returns true for linked models
      expect(modelController.isDownloaded('mistral-7b-instruct.Q4_K_M.gguf'), isTrue);
      expect(modelController.isDownloaded('deepseek-coder-6.7b.gguf'), isTrue);
    });

    test('externalModelPaths persistence and safe unlinking preserves user disk files', () async {
      final diskDir = Directory(p.join(tempDir.path, 'ssd_storage'));
      await diskDir.create(recursive: true);

      final externalFile = File(p.join(diskDir.path, 'llama3-8b.gguf'));
      await externalFile.writeAsBytes(List.filled(8192, 99));

      // Link model
      modelController.externalModelPaths['llama3-8b.gguf'] = externalFile.path;
      await hiveService.setSetting(
        AppConstants.keyExternalModelPaths,
        Map<String, String>.from(modelController.externalModelPaths),
      );

      // Verify Hive storage
      final storedMap = hiveService.getSetting<Map>(AppConstants.keyExternalModelPaths);
      expect(storedMap, isNotNull);
      expect(storedMap!['llama3-8b.gguf'], equals(externalFile.path));

      // Calling deleteModel on a linked model removes it from externalModelPaths and Hive
      await modelController.deleteModel('llama3-8b.gguf');

      expect(modelController.externalModelPaths.containsKey('llama3-8b.gguf'), isFalse);
      final updatedMap = hiveService.getSetting<Map>(AppConstants.keyExternalModelPaths);
      expect(updatedMap?.containsKey('llama3-8b.gguf') ?? false, isFalse);

      // Crucial: The original file on user's SSD is preserved (not deleted)
      expect(externalFile.existsSync(), isTrue);
    });

    test('refreshDownloaded reconciles and prunes dead external model paths', () async {
      final diskDir = Directory(p.join(tempDir.path, 'ephemeral_models'));
      await diskDir.create(recursive: true);

      final liveFile = File(p.join(diskDir.path, 'live.gguf'));
      await liveFile.writeAsBytes(List.filled(1024, 7));

      final deadPath = p.join(diskDir.path, 'deleted_externally.gguf');

      modelController.externalModelPaths['live.gguf'] = liveFile.path;
      modelController.externalModelPaths['deleted_externally.gguf'] = deadPath;
      await hiveService.setSetting(
        AppConstants.keyExternalModelPaths,
        Map<String, String>.from(modelController.externalModelPaths),
      );

      await modelController.refreshDownloaded();

      // live model is preserved
      expect(modelController.externalModelPaths.containsKey('live.gguf'), isTrue);
      expect(modelController.isDownloaded('live.gguf'), isTrue);

      // dead model path is pruned
      expect(modelController.externalModelPaths.containsKey('deleted_externally.gguf'), isFalse);
    });
  });
}
