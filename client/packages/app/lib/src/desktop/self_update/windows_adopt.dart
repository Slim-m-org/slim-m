// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Turns an extracted zip that is running in place into the per-user layout
/// from decision 0041, the same one `install.ps1` and the setup create, so
/// that copy can update itself from then on.
library;

import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'install_fs.dart';
import 'linux_layout.dart' show LayoutNames;
import 'self_update_failure.dart';
import 'windows_install.dart';
import 'windows_layout.dart';

/// Creates the Start menu shortcut to [launcher].
typedef CreateShortcut = Future<void> Function(File launcher);

/// Where the per-user layout lives: `%LOCALAPPDATA%\slim-m`, or null without it.
Directory? defaultWindowsLayoutRoot([Map<String, String>? environment]) {
  final base = (environment ?? Platform.environment)['LOCALAPPDATA'];
  return base == null || base.isEmpty
      ? null
      : Directory(p.join(base, 'slim-m'));
}

/// Whether [executable] is a bundle that can be moved into the layout: not a
/// system install, not already in the layout, and shipped with its launcher.
bool canAdoptWindowsInstall(String executable) =>
    !isSystemInstallPath(executable) &&
    detectWindowsLayout(executable) == null &&
    File(p.join(p.dirname(executable), WindowsNames.launcher)).existsSync();

/// Copies the running bundle into `app-<version>` under [root], installs its
/// launcher beside it and points `current` at it. The pointers go last, so a
/// failure on the way leaves nothing that would start the copy.
Future<WindowsInstallLayout> adoptWindowsInstall({
  required String executable,
  required String version,
  required Directory root,
  CreateShortcut createShortcut = createStartMenuShortcut,
  RenameDirectory rename = renameDirectoryOnce,
  List<Duration> backoff = renameBackoff,
}) async {
  if (!canAdoptWindowsInstall(executable)) {
    throw const SelfUpdateFailure(
      SelfUpdateFailureKind.unsupportedInstall,
      'This copy cannot be moved into a per-user install.',
    );
  }
  final layout = WindowsInstallLayout(root);
  try {
    root.createSync(recursive: true);
    await _publishBundle(
      p.dirname(executable),
      layout,
      version,
      rename,
      backoff,
    );
    _installLauncher(p.dirname(executable), layout);
    await createShortcut(layout.launcher);
    final before = layout.pointedVersion(LayoutNames.current);
    if (before != null && before != version) {
      writeWindowsPointer(layout, LayoutNames.previous, before);
    }
    safeDelete(File(layout.path(LayoutNames.pending)));
    safeDelete(File(layout.path(LayoutNames.pendingTries)));
    writeWindowsPointer(layout, LayoutNames.current, version);
    return layout;
  } on FileSystemException catch (error) {
    throw SelfUpdateFailure(
      SelfUpdateFailureKind.installFailed,
      'slim-m could not be installed for automatic updates.',
      detail: '$error',
    );
  } on ProcessException catch (error) {
    throw SelfUpdateFailure(
      SelfUpdateFailureKind.installFailed,
      'slim-m could not be installed for automatic updates.',
      detail: '$error',
    );
  }
}

Future<void> _publishBundle(
  String source,
  WindowsInstallLayout layout,
  String version,
  RenameDirectory rename,
  List<Duration> backoff,
) async {
  final target = layout.versionDir(version);
  if (isWindowsVersionComplete(target)) return;
  final scratch = Directory(layout.path('${LayoutNames.unpackPrefix}$version'));
  safeDelete(scratch);
  try {
    await Isolate.run(() => _copyTree(Directory(source), scratch));
    safeDelete(target);
    await renameDirectoryWithRetry(
      scratch,
      target.path,
      rename: rename,
      backoff: backoff,
    );
  } catch (_) {
    safeDelete(scratch);
    rethrow;
  }
}

void _copyTree(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final entry in from.listSync(followLinks: false)) {
    final destination = p.join(to.path, p.basename(entry.path));
    if (entry is Directory) {
      _copyTree(entry, Directory(destination));
    } else if (entry is File) {
      entry.copySync(destination);
    }
  }
}

void _installLauncher(String source, WindowsInstallLayout layout) {
  final temp = File(layout.path('.${WindowsNames.launcher}.new'));
  File(p.join(source, WindowsNames.launcher)).copySync(temp.path);
  temp.renameSync(layout.launcher.path);
}

const _shortcutScript =
    r"$s = (New-Object -ComObject WScript.Shell).CreateShortcut("
    r"(Join-Path ([Environment]::GetFolderPath('Programs')) 'slim-m.lnk')); "
    r'$s.TargetPath = $env:SLIMM_SHORTCUT_TARGET; $s.Save()';

/// The same shortcut `install.ps1` writes, made through WScript.Shell.
Future<void> createStartMenuShortcut(File launcher) async {
  final result = await Process.run(
    'powershell',
    ['-NoProfile', '-NonInteractive', '-Command', _shortcutScript],
    environment: {'SLIMM_SHORTCUT_TARGET': launcher.path},
  );
  if (result.exitCode != 0) {
    throw ProcessException(
      'powershell',
      const [],
      '${result.stderr}',
      result.exitCode,
    );
  }
}
