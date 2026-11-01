// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The native route: the bytes go to a temporary file, then `writeFile` on the
/// clipboard channel hands its path to the Linux or Windows runner.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'clipboard_file_writer.dart';

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
    file = await _stage(await bytes, filename);
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

/// Writes into a folder holding only the latest copy, so copies never pile up.
Future<File> _stage(Uint8List bytes, String filename) async {
  final dir = Directory(
    p.join((await getTemporaryDirectory()).path, 'slimm-clipboard'),
  );
  if (dir.existsSync()) await dir.delete(recursive: true);
  await dir.create(recursive: true);
  final file = File(p.join(dir.path, _safeName(filename)));
  await file.writeAsBytes(bytes, flush: true);
  return file;
}

String _safeName(String filename) {
  final base = p.basename(filename).replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  return base.trim().isEmpty ? 'file' : base;
}
