// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The native route: the bytes go to a temporary file, then `writeFile` on the
/// clipboard channel hands its path to the Linux or Windows runner.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'clipboard_file_writer.dart';
import 'clipboard_staging.dart';

const MethodChannel _channel = MethodChannel(
  'top.npcserver.slimm/clipboard_image',
);

// Only the desktop runners answer writeFile.
bool get supported => Platform.isLinux || Platform.isWindows;

Future<void> writeFile(
  Future<Uint8List> bytes, {
  required String filename,
}) async {
  if (!supported) {
    throw const ClipboardFileWriteException(
      'Copying files is not supported on this device.',
    );
  }
  final File file;
  try {
    final root = await clipboardStagingRoot(
      env: Platform.environment,
      tempPath: () async => (await getTemporaryDirectory()).path,
      isLinux: Platform.isLinux,
    );
    file = await stageClipboardFile(root, await bytes, filename);
  } on FileSystemException {
    throw const ClipboardFileWriteException('The file could not be prepared.');
  }
  try {
    await _channel.invokeMethod<void>('writeFile', file.path);
  } on MissingPluginException {
    throw const ClipboardFileWriteException(
      'Copying files is not supported on this device.',
    );
  } on PlatformException catch (e) {
    throw ClipboardFileWriteException(
      e.message ?? 'The clipboard refused the file.',
    );
  }
}
