// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The per-user Windows layout from decision 0041: one `app-<version>` folder
/// per version under `%LOCALAPPDATA%\slim-m`, beside a stable `slim-m.exe`
/// launcher and `current` and `previous` pointer files. The Go launcher in
/// `packaging/windows/launcher` reads the same file names, so they are shared.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../update_check.dart' show parseVersion;
import 'linux_layout.dart' show LayoutNames;
import 'package:slimm_api/api.dart' show AppLog, LogTag;

/// The names inside the layout that both the launcher and the app rely on.
abstract final class WindowsNames {
  static const launcher = 'slim-m.exe';
  static const appExecutable = 'slimm_app.exe';
  static const versionPrefix = 'app-';
}

class WindowsInstallLayout {
  const WindowsInstallLayout(this.root);

  final Directory root;

  String path(String name) => p.join(root.path, name);
  Directory versionDir(String version) =>
      Directory(path('${WindowsNames.versionPrefix}$version'));
  Directory get stagingDir => Directory(path(LayoutNames.staging));

  /// What a relaunch should run: the stable launcher, which reads `current`,
  /// so a pointer swap is picked up without knowing the new folder.
  File get launcher => File(path(WindowsNames.launcher));

  /// The version a pointer file names, or null when it is absent or empty.
  String? pointedVersion(String name) {
    try {
      final text = File(path(name)).readAsStringSync().trim();
      return text.isEmpty ? null : text;
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

  /// The version a folder name stands for, or null for anything else.
  static String? versionOfFolder(String folder) =>
      folder.startsWith(WindowsNames.versionPrefix) &&
          parseVersion(folder.substring(WindowsNames.versionPrefix.length)) !=
              null
      ? folder.substring(WindowsNames.versionPrefix.length)
      : null;

  /// Whether the person running this process can write in the root, probed by
  /// creating a file; a read-only tree never self-applies.
  bool get isWritable {
    try {
      final probe = File(path('.write-probe'))..writeAsStringSync('');
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
}

/// A machine-wide install (`Program Files`) or a packaged MSIX
/// (`WindowsApps`): both belong to the OS installer and are never rewritten.
bool isSystemInstallPath(String executable) {
  final normal = executable.replaceAll(r'\', '/').toLowerCase();
  return normal.contains('/windowsapps/') ||
      normal.contains('/program files/') ||
      normal.contains('/program files (x86)/');
}

/// The layout the running executable belongs to, or null when it is not the
/// per-user install: a plain extracted zip, an MSIX, a `Program Files` copy or
/// a `flutter run` build all lack the launcher and the `current` pointer.
WindowsInstallLayout? detectWindowsLayout(String resolvedExecutable) {
  if (isSystemInstallPath(resolvedExecutable)) return null;
  final versionDir = p.dirname(resolvedExecutable);
  if (WindowsInstallLayout.versionOfFolder(p.basename(versionDir)) == null) {
    return null;
  }
  final layout = WindowsInstallLayout(Directory(p.dirname(versionDir)));
  final hasPointer = File(layout.path(LayoutNames.current)).existsSync();
  return hasPointer && layout.launcher.existsSync() ? layout : null;
}
