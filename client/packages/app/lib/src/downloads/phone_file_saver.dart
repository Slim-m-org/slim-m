// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The platform save step for a finished phone download: a document picker on Android, the share sheet on iOS.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

/// Asks the activity to save a file through the document dialog, without reading it into Dart.
const MethodChannel _fileExportChannel = MethodChannel(
  'top.npcserver.slimm/file_export',
);

/// Android: the system "create document" dialog, then a native copy of the file into the chosen document.
Future<bool> documentFileSaver(File file, String filename) async {
  final saved = await _fileExportChannel.invokeMethod<bool>('saveCopy', {
    'path': file.path,
    'fileName': filename,
  });
  return saved ?? false;
}

/// iOS: the share sheet takes the file itself and offers Save to Files.
Future<bool> shareFileSaver(File file, String _) async {
  final result = await SharePlus.instance.share(
    ShareParams(files: [XFile(file.path)]),
  );
  return result.status != ShareResultStatus.dismissed;
}
