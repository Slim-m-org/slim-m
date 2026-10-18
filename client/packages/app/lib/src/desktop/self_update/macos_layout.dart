// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The per-user macOS install from decision 0041: one `.app` bundle the user
/// owns, with the previous bundle and a half-unpacked new one kept as hidden
/// siblings so every swap is a rename on one volume. The start-counting markers
/// live under Application Support, which never holds a bundle.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:slimm_api/api.dart' show AppLog, LogTag;

/// Marker files in the state directory, shared with nothing outside the app.
abstract final class MacosNames {
  static const pending = 'pending';
  static const pendingTries = 'pending.tries';
  static const rolledBack = 'rolled-back';
  static const failedVersion = 'failed-version';
  static const staging = '.staging';
  static const appSuffix = '.app';
}

class MacosInstallLayout {
  const MacosInstallLayout({
    required this.bundle,
    required this.executableName,
    required this.stateDir,
  });

  final Directory bundle;
  final String executableName;
  final Directory stateDir;

  Directory get parent => bundle.parent;
  String get _bundleName => p.basename(bundle.path);

  /// Where the verified new bundle waits before the swap.
  Directory get newBundle =>
      Directory(p.join(parent.path, '.$_bundleName.new'));

  /// The bundle that ran before the last update, kept until a clean start.
  Directory get previousBundle =>
      Directory(p.join(parent.path, '.$_bundleName.previous'));

  /// A bundle that failed to start, moved aside while the previous one returns.
  Directory get failedBundle =>
      Directory(p.join(parent.path, '.$_bundleName.failed'));

  /// Where a zip is unpacked before its `.app` is picked out.
  Directory get unpackDir =>
      Directory(p.join(parent.path, '.$_bundleName.unpack'));

  String path(String name) => p.join(stateDir.path, name);
  Directory get stagingDir => Directory(path(MacosNames.staging));

  /// What a relaunch runs: the executable inside the bundle at its stable path.
  File get launcher =>
      File(p.join(bundle.path, 'Contents', 'MacOS', executableName));

  /// Whether this process can replace the bundle: the folder holding it, the
  /// bundle itself and the state directory must all take a new file.
  bool get isWritable =>
      _canWrite(parent) &&
      _canWrite(Directory(p.join(bundle.path, 'Contents'))) &&
      _canWrite(stateDir);
}

bool _canWrite(Directory dir) {
  try {
    dir.createSync(recursive: true);
    final probe = File(p.join(dir.path, '.write-probe'))..writeAsStringSync('');
    probe.deleteSync();
    return true;
  } on FileSystemException catch (error, stack) {
    AppLog.swallowed(
      LogTag.platform,
      'can write failed, ignored',
      error,
      stack,
    );
    return false;
  }
}

/// Where the OS or a mounted image owns the bundle, so it is never rewritten:
/// system and library apps, a disk image, and Gatekeeper's translocated copy.
bool isManagedBundlePath(String executable) =>
    executable.startsWith('/System/') ||
    executable.startsWith('/Library/') ||
    executable.startsWith('/Volumes/') ||
    executable.startsWith('/opt/homebrew/Caskroom/') ||
    executable.contains('/AppTranslocation/') ||
    executable.contains('/Library/Containers/');

/// The layout the running executable belongs to, or null when it is not a
/// bundle the updater may replace: outside a `<name>.app/Contents/MacOS`, a
/// managed location, or an App Store build (it carries a `_MASReceipt`).
MacosInstallLayout? detectMacosLayout(
  String resolvedExecutable, {
  required String home,
}) {
  if (isManagedBundlePath(resolvedExecutable)) return null;
  final macOsDir = p.dirname(resolvedExecutable);
  final contents = p.dirname(macOsDir);
  final bundlePath = p.dirname(contents);
  if (p.basename(macOsDir) != 'MacOS' ||
      p.basename(contents) != 'Contents' ||
      !bundlePath.endsWith(MacosNames.appSuffix)) {
    return null;
  }
  if (Directory(p.join(contents, '_MASReceipt')).existsSync()) return null;
  return MacosInstallLayout(
    bundle: Directory(bundlePath),
    executableName: p.basename(resolvedExecutable),
    stateDir: Directory(
      p.join(home, 'Library', 'Application Support', 'slim-m', 'self-update'),
    ),
  );
}
