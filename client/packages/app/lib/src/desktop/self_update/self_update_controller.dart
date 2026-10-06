// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Drives one self-update from the UI: download and verify, install into the
/// per-user layout, and keep the outcome where the persistent error banner and
/// the title-bar menu read it. Only the per-user Linux, Windows and macOS layouts apply.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_platform/platform.dart';

import '../relaunch.dart';
import 'linux_install.dart' show Unpack;
import 'rollback_record.dart';
import 'self_update.dart';
import 'self_update_failure.dart';
import 'self_update_target.dart';

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
    http.Client Function() newClient = http.Client.new,
    Future<void> Function() restart = _relaunchAndExit,
  }) : _fetch = fetch,
       _unpack = unpack,
       _newClient = newClient,
       _restart = restart;

  final Ref ref;
  final FetchUpdate _fetch;
  final Unpack? _unpack;
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
  }) async {
    if (ref.read(selfUpdateInstallingProvider)) return null;
    ref.read(selfUpdateInstallingProvider.notifier).state = true;
    ref.read(selfUpdateFailureProvider.notifier).state = null;
    final client = _newClient();
    try {
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
    } on SelfUpdateFailure catch (failure) {
      ref.read(selfUpdateFailureProvider.notifier).state = failure;
      return null;
    } catch (error) {
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
  }
}
