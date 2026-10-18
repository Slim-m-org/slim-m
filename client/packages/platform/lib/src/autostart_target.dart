// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a login launch should run: the stable launcher of a self-updating
/// per-user install, never a versioned folder the next update replaces.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

final _versionName = RegExp(r'^\d+\.\d+\.\d+');
const _windowsFolderPrefix = 'app-';
const _windowsLauncher = 'slim-m.exe';
const _linuxLauncher = 'slim-m';

/// The root launcher beside the `app-<version>` folder holding [resolvedExecutable],
/// or [resolvedExecutable] itself for a bare copy, `Program Files` or MSIX.
String windowsAutostartExecutable(String resolvedExecutable) {
  final normal = resolvedExecutable.replaceAll(r'\', '/').toLowerCase();
  final systemOwned = normal.contains('/windowsapps/') ||
      normal.contains('/program files/') ||
      normal.contains('/program files (x86)/');
  final folder = p.dirname(resolvedExecutable);
  final name = p.basename(folder);
  if (systemOwned ||
      !name.startsWith(_windowsFolderPrefix) ||
      !_versionName.hasMatch(name.substring(_windowsFolderPrefix.length))) {
    return resolvedExecutable;
  }
  final root = p.dirname(folder);
  final launcher = p.join(root, _windowsLauncher);
  final managed =
      File(p.join(root, 'current')).existsSync() && File(launcher).existsSync();
  return managed ? launcher : resolvedExecutable;
}

/// The `current/slim-m` launcher of the per-user tarball layout, whose
/// `current` symlink follows updates, or [resolvedExecutable] outside it.
String linuxAutostartExecutable(String resolvedExecutable) {
  final folder = p.dirname(resolvedExecutable);
  if (!_versionName.hasMatch(p.basename(folder))) return resolvedExecutable;
  final root = p.dirname(folder);
  final current = p.join(root, 'current');
  final isLink = FileSystemEntity.typeSync(current, followLinks: false) ==
      FileSystemEntityType.link;
  return isLink ? p.join(current, _linuxLauncher) : resolvedExecutable;
}
