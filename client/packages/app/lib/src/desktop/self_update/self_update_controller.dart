// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Drives one self-update from the UI: download and verify, install into the
/// per-user layout, and keep the outcome where the persistent error banner and
/// the title-bar menu read it. Only the per-user Linux, Windows and macOS layouts apply.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:slimm_platform/platform.dart';

import '../relaunch.dart';
import 'linux_install.dart' show Unpack;
import 'windows_adopt.dart';
import 'windows_launcher_check.dart';
import 'windows_layout.dart';
import 'rollback_record.dart';
import 'self_update.dart';
import 'self_update_failure.dart';
import 'self_update_target.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag, reportFailure;

/// Moves a bare Windows bundle into the per-user layout; injectable so tests
/// need no real copy.
typedef AdoptInstall =
    Future<WindowsInstallLayout> Function({
      required String executable,
      required String version,
      required Directory root,
    });

Future<WindowsInstallLayout> _adoptInstall({
  required String executable,
  required String version,
  required Directory root,
}) => adoptWindowsInstall(executable: executable, version: version, root: root);

/// Fetch step, injectable so tests need no network.
typedef FetchUpdate =
    Future<VerifiedUpdate?> Function({
      required String currentVersion,
      required String platformKey,
      required Directory stagingDir,
      required http.Client client,
    });

Future<void> _relaunchAndExit() async {
  await spawnRelaunch();
  exit(0);
}

/// The install this process runs from when it may replace itself, else null.
SelfUpdateTarget? selfApplyTarget({
  InstallFormat? format,
  String? resolvedExecutable,
  String? os,
  String? home,
  String? arch,
}) {
  if ((format ?? currentInstallFormat()) != InstallFormat.tarball) return null;
  final target = installTargetFor(
    resolvedExecutable ?? Platform.resolvedExecutable,
    os ?? Platform.operatingSystem,
    home: home,
    arch: arch,
  );
  return target != null && target.isWritable ? target : null;
}

/// Whether this process may replace itself; overridable in tests.
final selfApplyAvailableProvider = Provider<bool>(
  (ref) => selfApplyTarget() != null,
);

/// The version installed and waiting for a restart, or null.
final stagedUpdateVersionProvider = StateProvider<String?>((ref) => null);

final selfUpdateInstallingProvider = StateProvider<bool>((ref) => false);

/// The last failure, shown by the persistent banner until dismissed.
final selfUpdateFailureProvider = StateProvider<SelfUpdateFailure?>(
  (ref) => null,
);

final selfUpdateProvider = Provider<SelfUpdateController>(
  SelfUpdateController.new,
);

/// [SelfUpdateController.countStart] for `main`, which has no container yet at
/// the point it must run: ahead of every step that can crash.
Future<void> countLaunch() async {
  final container = ProviderContainer();
  try {
    await container.read(selfUpdateProvider).countStart();
  } finally {
    container.dispose();
  }
}

class SelfUpdateController {
  SelfUpdateController(
    this.ref, {
    FetchUpdate fetch = fetchVerifiedUpdate,
    Unpack? unpack,
    AdoptInstall adopt = _adoptInstall,
    http.Client Function() newClient = http.Client.new,
    Future<void> Function() restart = _relaunchAndExit,
  }) : _fetch = fetch,
       _adopt = adopt,
       _unpack = unpack,
       _newClient = newClient,
       _restart = restart;

  final Ref ref;
  final FetchUpdate _fetch;
  final Unpack? _unpack;
  final AdoptInstall _adopt;
  final http.Client Function() _newClient;
  final Future<void> Function() _restart;

  /// Installs the newest verified release and returns its version, or null
  /// when there was nothing to install or it failed; a failure is left in
  /// [selfUpdateFailureProvider].
  Future<String?> install({
    required String currentVersion,
    InstallFormat? format,
    String? resolvedExecutable,
    String? os,
  }) => _guarded(
    (client) => _apply(
      client,
      currentVersion: currentVersion,
      format: format,
      resolvedExecutable: resolvedExecutable,
      os: os,
    ),
  );

  /// [install] for a bare Windows bundle: first moves it into the per-user
  /// layout, then updates from there. Relaunches go through the new launcher
  /// from then on. A failure carries [releaseUrl] so the banner can fall back
  /// to the release page.
  Future<String?> adoptAndInstall({
    required String currentVersion,
    required String releaseUrl,
    String? executable,
    Directory? root,
  }) => _guarded((client) async {
    final layoutRoot = root ?? defaultWindowsLayoutRoot();
    if (layoutRoot == null) {
      throw SelfUpdateFailure(
        SelfUpdateFailureKind.installFailed,
        'slim-m could not find your local app data folder.',
        releaseUrl: releaseUrl,
      );
    }
    final bundle = executable ?? Platform.resolvedExecutable;
    final WindowsInstallLayout layout;
    try {
      layout = await _adopt(
        executable: bundle,
        version: currentVersion,
        root: layoutRoot,
      );
    } on SelfUpdateFailure catch (failure) {
      throw SelfUpdateFailure(
        failure.kind,
        failure.message,
        detail: failure.detail,
        releaseUrl: releaseUrl,
      );
    }
    relaunchLauncherOverride = layout.launcher.path;
    return _apply(
      client,
      currentVersion: currentVersion,
      format: InstallFormat.tarball,
      resolvedExecutable: p.join(
        layout.versionDir(currentVersion).path,
        WindowsNames.appExecutable,
      ),
      os: 'windows',
    );
  });

  Future<String?> _guarded(
    Future<String?> Function(http.Client client) body,
  ) async {
    if (ref.read(selfUpdateInstallingProvider)) return null;
    ref.read(selfUpdateInstallingProvider.notifier).state = true;
    ref.read(selfUpdateFailureProvider.notifier).state = null;
    final client = _newClient();
    try {
      return await body(client);
    } on SelfUpdateFailure catch (failure, stack) {
      AppLog.swallowed(
        LogTag.platform,
        'The update could not be installed; showing the reason',
        failure,
        stack,
      );
      ref.read(selfUpdateFailureProvider.notifier).state = failure;
      return null;
    } catch (error, stack) {
      reportFailure(LogTag.platform, 'install the update', error, stack);
      ref.read(selfUpdateFailureProvider.notifier).state = SelfUpdateFailure(
        SelfUpdateFailureKind.installFailed,
        'The update could not be installed, so this version is unchanged.',
        detail: '$error',
      );
      return null;
    } finally {
      client.close();
      ref.read(selfUpdateInstallingProvider.notifier).state = false;
    }
  }

  Future<String?> _apply(
    http.Client client, {
    required String currentVersion,
    InstallFormat? format,
    String? resolvedExecutable,
    String? os,
  }) async {
    final target = selfApplyTarget(
      format: format,
      resolvedExecutable: resolvedExecutable,
      os: os,
    );
    if (target == null) {
      throw const SelfUpdateFailure(
        SelfUpdateFailureKind.unsupportedInstall,
        'This install is updated by its package manager, not by slim-m.',
      );
    }
    // A rolled-back version counts as installed, or it is fetched again on every launch.
    final update = await _fetch(
      currentVersion: versionToUpdateFrom(
        currentVersion,
        target.failedVersion(),
      ),
      platformKey: target.platformKey,
      stagingDir: target.stagingDir,
      client: client,
    );
    if (update == null) return null;
    await target.install(update, unpack: _unpack);
    ref.read(stagedUpdateVersionProvider.notifier).state = update.version;
    return update.version;
  }

  /// Counts this launch and, where the app is its own launcher (macOS), puts
  /// the previous version back when the new one keeps failing, then restarts.
  ///
  /// Called before anything in startup can throw: counting from [confirmStart],
  /// which only runs once the app is ready, never saw the native-load,
  /// bootstrap and database failures that rollback exists for.
  Future<void> countStart({
    String? resolvedExecutable,
    String? os,
    String? home,
  }) async {
    if (resolvedExecutable == null && !isDesktopHost) return;
    final target = installTargetFor(
      resolvedExecutable ?? Platform.resolvedExecutable,
      os ?? Platform.operatingSystem,
      home: home,
    );
    if (target != null && target.rollBackIfStuck()) await _restart();
  }

  /// Startup bookkeeping: report a rollback the launcher performed, and after
  /// [settle] of staying up mark this launch clean so old versions are pruned.
  Future<void> confirmStart({
    String? resolvedExecutable,
    String? os,
    String? home,
    Duration settle = const Duration(seconds: 20),
  }) async {
    if (resolvedExecutable == null && !isDesktopHost) return;
    final target = installTargetFor(
      resolvedExecutable ?? Platform.resolvedExecutable,
      os ?? Platform.operatingSystem,
      home: home,
    );
    if (target == null) return;
    final failed = target.takeRollbackNotice();
    if (failed != null) {
      ref.read(selfUpdateFailureProvider.notifier).state = SelfUpdateFailure(
        SelfUpdateFailureKind.rolledBack,
        'Version $failed did not start, so slim-m went back to the '
        'previous version.',
      );
    }
    await Future<void>.delayed(settle);
    target.confirmCleanStart();
    await _noteOutdatedLauncher(resolvedExecutable, os);
  }

  Future<void> _noteOutdatedLauncher(
    String? resolvedExecutable,
    String? os,
  ) async {
    if ((os ?? Platform.operatingSystem) != 'windows') return;
    if (ref.read(selfUpdateFailureProvider) != null) return;
    final layout = detectWindowsLayout(
      resolvedExecutable ?? Platform.resolvedExecutable,
    );
    if (layout == null) return;
    final notice = await outdatedLauncherNotice(layout);
    if (notice != null) {
      ref.read(selfUpdateFailureProvider.notifier).state = notice;
    }
  }
}
