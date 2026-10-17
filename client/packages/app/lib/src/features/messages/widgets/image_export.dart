// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Getting an opened image out of the app: the system share sheet, the photo
/// library, or a file the reader names.
///
/// Which of those exist is a question about the host's system integration, so
/// it is answered from the platform here and nowhere in the viewer's layout:
/// a phone has a share sheet and a photo library, a desktop window has
/// neither and gets a Save as dialog, and the browser downloads. The native
/// calls sit behind [ImageExporter] so a widget test can drive the mobile
/// branch, which `flutter test` on Linux would otherwise never reach.
library;

import 'dart:io';
import 'dart:ui' show Rect;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// What the viewer's action bar offers, and what each action does.
abstract class ImageExporter {
  /// True where an OS share sheet exists; the control is absent otherwise.
  bool get canShare;

  /// True where the photo library is the save target, false where Save is a
  /// file dialog or a browser download.
  bool get savesToLibrary;

  Future<void> share(
    Uint8List bytes, {
    required String filename,
    required String contentType,
    Rect? origin,
  });

  /// Returns false when the reader cancelled a save dialog, true otherwise.
  Future<bool> save(Uint8List bytes, {required String filename});
}

/// Thrown by [ImageExporter.save] when the photo library refused access.
class PhotoLibraryDenied implements Exception {
  const PhotoLibraryDenied();
}

class PlatformImageExporter implements ImageExporter {
  /// [tempRoot] and [shareFiles] are seams so a test can watch the temp file.
  const PlatformImageExporter({this.tempRoot, this.shareFiles});

  final Future<Directory> Function()? tempRoot;
  final Future<void> Function(ShareParams params)? shareFiles;

  static bool get _mobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  bool get canShare => _mobile;

  @override
  bool get savesToLibrary => _mobile;

  @override
  Future<void> share(
    Uint8List bytes, {
    required String filename,
    required String contentType,
    Rect? origin,
  }) async {
    final root = await (tempRoot ?? getTemporaryDirectory)();
    // share_plus never deletes the copy it makes of XFile.fromData.
    await _sweep(root);
    final folder = await root.createTemp(_folderPrefix);
    try {
      final file = File(
        '${folder.path}/${filename.split(RegExp(r'[\\/]')).last}',
      );
      await file.writeAsBytes(bytes);
      final params = ShareParams(
        files: [XFile(file.path, mimeType: contentType)],
        sharePositionOrigin: origin,
      );
      await (shareFiles ?? SharePlus.instance.share)(params);
    } finally {
      // Android's chooser reports back before the target app has read the file.
      if (!_deferDelete) await folder.delete(recursive: true);
    }
  }

  static const _folderPrefix = 'share_';

  static bool get _deferDelete =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Clears what an earlier share left behind, which is all of it on Android.
  static Future<void> _sweep(Directory root) async {
    await for (final entry in root.list()) {
      if (entry is Directory &&
          entry.uri.pathSegments
              .lastWhere((s) => s.isNotEmpty)
              .startsWith(_folderPrefix)) {
        await entry.delete(recursive: true).catchError((_) => entry);
      }
    }
  }

  @override
  Future<bool> save(Uint8List bytes, {required String filename}) async {
    if (!_mobile) {
      final path = await FilePicker.saveFile(fileName: filename, bytes: bytes);
      // A web download also returns null, so null only means cancelled off the web.
      return kIsWeb || path != null;
    }
    try {
      await Gal.putImageBytes(bytes, name: filename);
      return true;
    } on GalException catch (e) {
      if (e.type == GalExceptionType.accessDenied) {
        throw const PhotoLibraryDenied();
      }
      rethrow;
    }
  }
}

final imageExporterProvider = Provider<ImageExporter>(
  (ref) => const PlatformImageExporter(),
);
