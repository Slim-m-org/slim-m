// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The switch half of decision 0041 for the per-user Windows install: unpack a
/// verified zip into its own `app-<version>` folder, then rewrite the `current`
/// pointer through a temp file and a replacing rename, so a launcher reads the
/// old version or the new one, never neither. Rollback on a bad start lives in
/// the launcher; pruning waits for [confirmWindowsCleanStart].
library;

import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:slimm_platform/platform.dart';

import 'install_fs.dart';
import 'linux_install.dart' show Unpack;
import 'linux_layout.dart' show LayoutNames;
import 'rollback_record.dart';
import 'self_update.dart';
import 'self_update_failure.dart';
import 'windows_layout.dart';

/// Extracts [archive] into [destination]. Every entry must land inside it; one
/// that would escape, or fail to write, fails the whole unpack.
Future<void> unpackZip(File archive, Directory destination) => Isolate.run(() {
  final input = InputFileStream(archive.path);
  try {
    final root = p.canonicalize(destination.path);
    for (final entry in ZipDecoder().decodeStream(input)) {
      final target = p.canonicalize(p.join(root, p.normalize(entry.name)));
      if (!p.isWithin(root, target)) {
        throw FileSystemException('zip entry escapes the folder', entry.name);
      }
      if (!entry.isFile) {
        Directory(target).createSync(recursive: true);
        continue;
      }
      Directory(p.dirname(target)).createSync(recursive: true);
      File(target).writeAsBytesSync(entry.content);
    }
  } finally {
    input.closeSync();
  }
});

/// Installs [update] beside the running version and points `current` at it.
/// Refuses any install that is not the per-user layout, and leaves the
/// pointer untouched on every failure before its final rename.
Future<void> installWindowsUpdate({
  required VerifiedUpdate update,
  required InstallFormat format,
  required WindowsInstallLayout? layout,
  Unpack unpack = unpackZip,
}) async {
  if (format != InstallFormat.tarball || layout == null || !layout.isWritable) {
    throw const SelfUpdateFailure(
      SelfUpdateFailureKind.unsupportedInstall,
      'This install is not the per-user one, so slim-m cannot update it. '
      'Download the new version from the release page.',
    );
  }
  try {
    await _publishVersion(update, layout, unpack);
    final before = layout.pointedVersion(LayoutNames.current);
    if (before != null && before != update.version) {
      _writePointer(layout, LayoutNames.previous, before);
    }
    File(layout.path(LayoutNames.pending)).writeAsStringSync(update.version);
    safeDelete(File(layout.path(LayoutNames.pendingTries)));
    _writePointer(layout, LayoutNames.current, update.version);
    safeDelete(update.file);
  } on FileSystemException catch (error) {
    throw SelfUpdateFailure(
      SelfUpdateFailureKind.installFailed,
      'The update could not be installed, so this version is unchanged.',
      detail: '$error',
    );
  }
}

Future<void> _publishVersion(
  VerifiedUpdate update,
  WindowsInstallLayout layout,
  Unpack unpack,
) async {
  final target = layout.versionDir(update.version);
  if (_isComplete(target)) return;
  final scratch = Directory(
    layout.path('${LayoutNames.unpackPrefix}${update.version}'),
  );
  safeDelete(scratch);
  try {
    await scratch.create(recursive: true);
    await unpack(update.file, scratch);
    if (!_isComplete(scratch)) {
      throw const FileSystemException(
        'the zip has no ${WindowsNames.appExecutable}',
      );
    }
    safeDelete(target);
    await scratch.rename(target.path);
  } catch (_) {
    safeDelete(scratch);
    rethrow;
  }
}

bool _isComplete(Directory dir) =>
    File(p.join(dir.path, WindowsNames.appExecutable)).existsSync();

/// Writes [name] through a sibling temp file; the rename replaces an existing
/// file in one step (MoveFileEx with MOVEFILE_REPLACE_EXISTING on Windows).
void _writePointer(WindowsInstallLayout layout, String name, String version) {
  final temp = File(layout.path('.$name.new'))..writeAsStringSync(version);
  temp.renameSync(layout.path(name));
}

/// Run once the new version has stayed up: clears the pending-start marker so
/// the launcher stops counting, and prunes every version folder except
/// `current` and `previous` (the one kept for rollback).
void confirmWindowsCleanStart(WindowsInstallLayout layout) {
  safeDelete(File(layout.path(LayoutNames.pending)));
  safeDelete(File(layout.path(LayoutNames.pendingTries)));
  final keep = {
    layout.pointedVersion(LayoutNames.current),
    layout.pointedVersion(LayoutNames.previous),
  };
  for (final entry in layout.root.listSync(followLinks: false)) {
    final name = p.basename(entry.path);
    final version = WindowsInstallLayout.versionOfFolder(name);
    final stale =
        entry is Directory &&
        ((version != null && !keep.contains(version)) ||
            name == LayoutNames.staging ||
            name.startsWith(LayoutNames.unpackPrefix));
    if (stale) safeDelete(entry);
  }
}

/// The version the launcher rolled back from since the last call, if any.
/// Reading it clears the marker so the failure is reported once, and records it
/// so the update pass never installs it again.
String? takeWindowsRollbackNotice(WindowsInstallLayout layout) =>
    takeRolledBack(
      rolledBack: File(layout.path(LayoutNames.rolledBack)),
      record: File(layout.path(LayoutNames.failedVersion)),
    );
