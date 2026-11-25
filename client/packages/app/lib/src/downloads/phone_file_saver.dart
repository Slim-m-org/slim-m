// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The platform save step for a finished phone download: a document picker on Android, the share sheet on iOS.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import 'download_target_phone.dart';

/// Asks the activity to copy a file to a document the user picked, without reading it into Dart.
const MethodChannel _fileExportChannel = MethodChannel(
  'top.npcserver.slimm/file_export',
);

/// The save step for this phone; Android and iOS only.
PhoneFileSaver platformPhoneFileSaver() =>
    Platform.isIOS ? shareFileSaver : documentFileSaver;

/// Android: the picker creates an empty document, then the platform copies the file into it.
Future<bool> documentFileSaver(File file, String filename) async {
  final document = await FilePicker.saveFile(
    fileName: filename,
    bytes: Uint8List(0),
  );
  if (document == null) return false;
  await _fileExportChannel.invokeMethod<void>('copyToDocument', {
    'path': file.path,
    'document': document.toString(),
  });
  return true;
}

/// iOS: the share sheet takes the file itself and offers Save to Files.
Future<bool> shareFileSaver(File file, String _) async {
  final result = await SharePlus.instance.share(
    ShareParams(files: [XFile(file.path)]),
  );
  return result.status != ShareResultStatus.dismissed;
}
