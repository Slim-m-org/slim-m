// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The switch half of decision 0041 for the per-user Linux tarball: unpack a
/// verified tarball into its own version directory, then move `current` onto
/// it with a rename so a reader sees the old version or the new one, never
/// neither. Rollback on a bad start lives in the launcher; pruning waits for
/// [confirmCleanStart].
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:slimm_platform/platform.dart';

import '../update_check.dart' show parseVersion;
import 'install_fs.dart';
import 'linux_layout.dart';
import 'rollback_record.dart';
import 'self_update.dart';
import 'self_update_failure.dart';

/// Unpacks [archive] into [destination], dropping the tarball's one top-level
/// directory. Injectable so tests do not need a real `tar`.
typedef Unpack = Future<void> Function(File archive, Directory destination);

Future<void> unpackWithTar(File archive, Directory destination) async {
  final done = await Process.run('tar', [
    '-xzf',
    archive.path,
    '-C',
    destination.path,
    '--strip-components=1',
  ]);
  if (done.exitCode != 0) throw FileSystemException('${done.stderr}');
}

/// Installs [update] beside the running version and makes it `current`.
/// Refuses any install that is not the per-user tarball layout, and leaves
/// `current` untouched on every failure before the final rename.
Future<void> installLinuxUpdate({
  required VerifiedUpdate update,
  required InstallFormat format,
  required LinuxInstallLayout? layout,
  Unpack unpack = unpackWithTar,
}) async {
  if (format != InstallFormat.tarball ||
      layout == null ||
      !layoutIsWritable(layout)) {
    throw const SelfUpdateFailure(
      SelfUpdateFailureKind.unsupportedInstall,
      'This install is updated by its package manager, not by slim-m.',
    );
  }
  try {
    await _publishVersion(update, layout, unpack);
    final before = layout.linkedVersion(LayoutNames.current);
    if (before != null && before != update.version) {
      _swapLink(layout, LayoutNames.previous, before);
    }
    File(layout.path(LayoutNames.pending)).writeAsStringSync(update.version);
    safeDelete(File(layout.path(LayoutNames.pendingTries)));
    _swapLink(layout, LayoutNames.current, update.version);
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
  LinuxInstallLayout layout,
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
      throw const FileSystemException('the tarball has no slimm_app or slim-m');
    }
    safeDelete(target);
    await scratch.rename(target.path);
  } catch (_) {
    safeDelete(scratch);
    rethrow;
  }
}

bool _isComplete(Directory dir) =>
    File(p.join(dir.path, 'slimm_app')).existsSync() &&
    File(p.join(dir.path, 'slim-m')).existsSync();

/// Points [name] at [version] through a temp link and rename(2), which
/// replaces an existing link in one step.
void _swapLink(LinuxInstallLayout layout, String name, String version) {
  final temp = Link(layout.path('.$name.new'));
  if (temp.existsSync()) temp.deleteSync();
  temp.createSync(version);
  temp.renameSync(layout.path(name));
}

/// Run once the new version has stayed up: clears the pending-start marker so
/// the launcher stops counting, and prunes every version directory except
/// `current` and `previous` (the one kept for rollback).
void confirmCleanStart(LinuxInstallLayout layout) {
  safeDelete(File(layout.path(LayoutNames.pending)));
  safeDelete(File(layout.path(LayoutNames.pendingTries)));
  final keep = {
    layout.linkedVersion(LayoutNames.current),
    layout.linkedVersion(LayoutNames.previous),
  };
  for (final entry in layout.root.listSync(followLinks: false)) {
    final name = p.basename(entry.path);
    final stale =
        entry is Directory &&
        !keep.contains(name) &&
        (parseVersion(name) != null ||
            name == LayoutNames.staging ||
            name.startsWith(LayoutNames.unpackPrefix));
    if (stale) safeDelete(entry);
  }
}

/// The version the launcher rolled back from since the last call, if any.
/// Reading it clears the marker so the failure is reported once, and records it
/// so the update pass never installs it again.
String? takeRollbackNotice(LinuxInstallLayout layout) => takeRolledBack(
  rolledBack: File(layout.path(LayoutNames.rolledBack)),
  record: File(layout.path(LayoutNames.failedVersion)),
);
