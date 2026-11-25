// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where a copied file is staged so the host clipboard can reach it, and how a
/// copy gets its own folder.
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'safe_file_name.dart';

/// The folder every staged copy lives under.
///
/// A flatpak's own `/tmp` is private to the sandbox, so a path there means
/// nothing to the host app that pastes it. `$XDG_RUNTIME_DIR/app/$FLATPAK_ID`
/// is bind-mounted at the same path on the host, and a native Linux install
/// keeps the copy out of the shared `/tmp` for the same reason.
Future<Directory> clipboardStagingRoot({
  required Map<String, String> env,
  required Future<String> Function() tempPath,
  required bool isLinux,
}) async {
  final runtime = env['XDG_RUNTIME_DIR'];
  final hasRuntime = isLinux && runtime != null && runtime.isNotEmpty;
  final flatpakId = env['FLATPAK_ID'];
  if (hasRuntime && flatpakId != null && flatpakId.isNotEmpty) {
    return Directory(p.join(runtime, 'app', flatpakId, 'slimm-clipboard'));
  }
  if (hasRuntime) return Directory(p.join(runtime, 'slimm-clipboard'));
  return Directory(p.join(await tempPath(), 'slimm-clipboard'));
}

/// Writes [bytes] as [filename] in a folder of its own under [root], then
/// removes the folders earlier copies left, ignoring any a program still holds.
Future<File> stageClipboardFile(
  Directory root,
  Uint8List bytes,
  String filename,
) async {
  final dir = Directory(p.join(root.path, _uniqueName()));
  await dir.create(recursive: true);
  final file = File(p.join(dir.path, safeFileName(filename)));
  await file.writeAsBytes(bytes, flush: true);
  await _sweepOthers(root, keep: dir);
  return file;
}

Future<void> _sweepOthers(Directory root, {required Directory keep}) async {
  try {
    await for (final entry in root.list(followLinks: false)) {
      if (entry.path == keep.path) continue;
      try {
        await entry.delete(recursive: true);
      } on FileSystemException {
        // Another program still holds it; the next copy sweeps it.
      }
    }
  } on FileSystemException {
    // Nothing to sweep.
  }
}

String _uniqueName() {
  final rng = Random.secure();
  final suffix = List.generate(
    4,
    (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  return '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-$suffix';
}
