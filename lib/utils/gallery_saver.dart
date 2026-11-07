import 'dart:io' show Platform, Directory, File;
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Cross-platform helper to save image bytes to the photo gallery (mobile/macOS)
/// or directly to Pictures/Downloads directory on desktop (Windows/Linux).
class GallerySaver {
  /// Saves the given image [bytes] to the appropriate destination for the current platform.
  /// Returns a user-friendly destination string or file path.
  static Future<String> saveImageBytes(Uint8List bytes, {String? name}) async {
    // Mobile and macOS have native gallery support via Gal
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS)) {
      final hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        final granted = await Gal.requestAccess();
        if (!granted) {
          throw Exception('Cannot save images without gallery access permission.');
        }
      }
      await Gal.putImageBytes(bytes, name: name);
      return 'gallery';
    } else {
      // Windows, Linux or fallback: write directly to user's Pictures or Downloads directory
      Directory? targetDir;
      try {
        targetDir = await getPicturesDirectory() ?? await getDownloadsDirectory();
      } catch (_) {
        targetDir = await getDownloadsDirectory();
      }
      targetDir ??= await getApplicationDocumentsDirectory();

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileName = '${name ?? 'privatelm_$timestamp'}.png';
      final file = File(p.join(targetDir.path, fileName));
      await file.writeAsBytes(bytes);
      return file.path;
    }
  }
}
