// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The per-user Linux tarball layout from decision 0041: one directory per
/// version under a root, a `current` symlink saying which one runs, and a
/// `previous` symlink kept for rollback. The launcher in each version reads
/// and swaps the same files from shell, so the names here are shared with
/// `packaging/linux/slim-m`.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../update_check.dart' show parseVersion;
import 'package:slimm_api/api.dart' show AppLog, LogTag;

/// Files and links the launcher and the updater both use, in the layout root.
abstract final class LayoutNames {
  static const current = 'current';
  static const previous = 'previous';
  static const pending = 'pending';
  static const pendingTries = 'pending.tries';
  static const rolledBack = 'rolled-back';
  static const failedVersion = 'failed-version';
  static const staging = '.staging';
  static const unpackPrefix = '.unpack-';
}

class LinuxInstallLayout {
  const LinuxInstallLayout(this.root);

  final Directory root;

  String path(String name) => p.join(root.path, name);
  Directory versionDir(String version) => Directory(path(version));
  Directory get stagingDir => Directory(path(LayoutNames.staging));

  /// What a relaunch should exec: the launcher of whichever version `current`
  /// names now, so a swap is picked up without knowing the new path.
  File get launcher => File(p.join(path(LayoutNames.current), 'slim-m'));

  /// The version directory name a layout link points at, or null.
  String? linkedVersion(String linkName) {
    try {
      return p.basename(Link(path(linkName)).targetSync());
    } on FileSystemException catch (error, stack) {
      AppLog.swallowed(
        LogTag.platform,
        'Could not read which version is installed',
        error,
        stack,
      );
      return null;
    }
  }
}

/// The layout the running executable belongs to, or null when it is not a
/// per-user tarball install: a plain extracted tarball, an rpm's `/usr/lib`,
/// a flatpak, or a `flutter run` build all lack the `current` symlink.
LinuxInstallLayout? detectLinuxLayout(String resolvedExecutable) {
  final versionDir = p.dirname(resolvedExecutable);
  if (parseVersion(p.basename(versionDir)) == null) return null;
  final root = Directory(p.dirname(versionDir));
  final current = FileSystemEntity.typeSync(
    p.join(root.path, LayoutNames.current),
    followLinks: false,
  );
  if (current != FileSystemEntityType.link) return null;
  return LinuxInstallLayout(root);
}

/// Whether the person running this process can write in [layout]'s root,
/// probed by creating a file; a read-only or root-owned tree never self-applies.
bool layoutIsWritable(LinuxInstallLayout layout) {
  try {
    final probe = File(layout.path('.write-probe'))..writeAsStringSync('');
    probe.deleteSync();
    return true;
  } on FileSystemException catch (error, stack) {
    AppLog.swallowed(
      LogTag.platform,
      'The install folder is not writable; updating in place is off',
      error,
      stack,
    );
    return false;
  }
}
