// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The switch half of decision 0041 for the per-user macOS bundle: unpack the
/// verified zip beside the install, check the bundle is whole and signed, then
/// rename the running bundle aside and the new one into its place. There is no
/// launcher on macOS, so the app itself counts starts and moves the previous
/// bundle back on the third one that still finds the pending marker.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:slimm_platform/platform.dart';

import 'install_fs.dart';
import 'linux_install.dart' show Unpack;
import 'macos_layout.dart';
import 'rollback_record.dart';
import 'self_update.dart';
import 'self_update_failure.dart';

/// Throws [FileSystemException] when [bundle] should not be trusted to run.
typedef BundleCheck = Future<void> Function(Directory bundle);

/// `ditto` keeps the symlinks, modes and resource forks a signed bundle needs.
Future<void> unpackWithDitto(File archive, Directory destination) async {
  final done = await Process.run('ditto', [
    '-x',
    '-k',
    archive.path,
    destination.path,
  ]);
  if (done.exitCode != 0) throw FileSystemException('${done.stderr}');
}

/// An ad-hoc signature passes; a bundle that was altered or never signed does
/// not, and would be killed by the kernel on its first launch.
Future<void> verifySignature(Directory bundle) async {
  final done = await Process.run('codesign', [
    '--verify',
    '--deep',
    '--strict',
    bundle.path,
  ]);
  if (done.exitCode != 0) {
    throw FileSystemException(
      'the bundle signature is invalid: ${done.stderr}',
    );
  }
}

/// Best effort: a downloaded file has no quarantine flag, so absence is fine.
Future<void> clearQuarantine(Directory bundle) async {
  await Process.run('xattr', ['-dr', 'com.apple.quarantine', bundle.path]);
}

/// Installs [update] as the bundle at [layout] and leaves the old one beside
/// it. Refuses anything but the per-user bundle, and leaves the current bundle
/// untouched on every failure before the swap.
Future<void> installMacosUpdate({
  required VerifiedUpdate update,
  required InstallFormat format,
  required MacosInstallLayout? layout,
  Unpack unpack = unpackWithDitto,
  BundleCheck verify = verifySignature,
  BundleCheck stripQuarantine = clearQuarantine,
}) async {
  if (format != InstallFormat.tarball || layout == null || !layout.isWritable) {
    throw const SelfUpdateFailure(
      SelfUpdateFailureKind.unsupportedInstall,
      'This install is not one slim-m may replace, so it cannot update '
      'itself. Download the new version from the release page.',
    );
  }
  try {
    await _prepareNewBundle(layout, update, unpack, verify, stripQuarantine);
    _swapIn(layout);
    File(layout.path(MacosNames.pending)).writeAsStringSync(update.version);
    safeDelete(File(layout.path(MacosNames.pendingTries)));
    safeDelete(update.file);
  } on FileSystemException catch (error) {
    throw SelfUpdateFailure(
      SelfUpdateFailureKind.installFailed,
      'The update could not be installed, so this version is unchanged.',
      detail: '$error',
    );
  }
}

Future<void> _prepareNewBundle(
  MacosInstallLayout layout,
  VerifiedUpdate update,
  Unpack unpack,
  BundleCheck verify,
  BundleCheck stripQuarantine,
) async {
  safeDelete(layout.newBundle);
  safeDelete(layout.unpackDir);
  try {
    await layout.unpackDir.create(recursive: true);
    await unpack(update.file, layout.unpackDir);
    final unpacked = _theBundleIn(layout.unpackDir, layout.executableName);
    await unpacked.rename(layout.newBundle.path);
    await verify(layout.newBundle);
    await stripQuarantine(layout.newBundle);
  } catch (_) {
    safeDelete(layout.newBundle);
    rethrow;
  } finally {
    safeDelete(layout.unpackDir);
  }
}

/// The one `.app` an unpacked zip must hold, with the executable this install
/// runs and an Info.plist; anything else is not a bundle of this app.
Directory _theBundleIn(Directory unpacked, String executableName) {
  final apps = unpacked
      .listSync(followLinks: false)
      .whereType<Directory>()
      .where((d) => d.path.endsWith(MacosNames.appSuffix))
      .toList();
  if (apps.length != 1) {
    throw const FileSystemException('the zip does not hold exactly one .app');
  }
  final app = apps.single;
  final executable = File(
    p.join(app.path, 'Contents', 'MacOS', executableName),
  );
  final hasPlist = File(
    p.join(app.path, 'Contents', 'Info.plist'),
  ).existsSync();
  final runnable =
      executable.existsSync() && executable.statSync().mode & 0x49 != 0;
  if (!hasPlist || !runnable) {
    throw FileSystemException('the .app is not a bundle of this app', app.path);
  }
  return app;
}

/// Two renames on one volume: the bundle aside, then the new one in. If the
/// second fails the first is undone, so a failed swap never leaves no app.
void _swapIn(MacosInstallLayout layout) {
  safeDelete(layout.previousBundle);
  layout.bundle.renameSync(layout.previousBundle.path);
  try {
    layout.newBundle.renameSync(layout.bundle.path);
  } on FileSystemException {
    layout.previousBundle.renameSync(layout.bundle.path);
    rethrow;
  }
}

/// Counts a start of a just-installed bundle. The third start that still finds
/// the pending marker puts the previous bundle back; returns whether it did,
/// so the caller restarts into it.
bool rollBackMacosIfStuck(MacosInstallLayout layout) {
  final pending = File(layout.path(MacosNames.pending));
  if (!pending.existsSync() || !layout.previousBundle.existsSync()) {
    return false;
  }
  final triesFile = File(layout.path(MacosNames.pendingTries));
  final tries = int.tryParse(_readOr(triesFile, '0')) ?? 0;
  if (tries < 2) {
    triesFile.writeAsStringSync('${tries + 1}');
    return false;
  }
  final failedVersion = pending.readAsStringSync().trim();
  try {
    safeDelete(layout.failedBundle);
    layout.bundle.renameSync(layout.failedBundle.path);
    layout.previousBundle.renameSync(layout.bundle.path);
  } on FileSystemException {
    return false;
  }
  File(layout.path(MacosNames.rolledBack)).writeAsStringSync(failedVersion);
  safeDelete(pending);
  safeDelete(triesFile);
  safeDelete(layout.failedBundle);
  return true;
}

String _readOr(File file, String fallback) {
  try {
    return file.readAsStringSync().trim();
  } on FileSystemException {
    return fallback;
  }
}

/// Run once the new bundle has stayed up: stops the start counting and deletes
/// every leftover of an earlier attempt, keeping one previous bundle to go back to.
void confirmMacosCleanStart(MacosInstallLayout layout) {
  safeDelete(File(layout.path(MacosNames.pending)));
  safeDelete(File(layout.path(MacosNames.pendingTries)));
  safeDelete(layout.failedBundle);
  safeDelete(layout.newBundle);
  safeDelete(layout.unpackDir);
  safeDelete(layout.stagingDir);
}

/// The version the app rolled back from since the last call, if any.
/// Reading it clears the marker so the failure is reported once, and records it
/// so the update pass never installs it again.
String? takeMacosRollbackNotice(MacosInstallLayout layout) => takeRolledBack(
  rolledBack: File(layout.path(MacosNames.rolledBack)),
  record: File(layout.path(MacosNames.failedVersion)),
);
