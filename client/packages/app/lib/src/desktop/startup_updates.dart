// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the splash does about updates, per decision 0025: unless the person
/// turned it off in Settings, fetch and install a newer version during the
/// mini splash before the app starts. Nothing is asked here; on is the default.
///
/// Nothing here may fail startup. Every step is timeout-bounded or
/// best-effort, and any error falls through to launching the client that is
/// already installed.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:slimm_platform/platform.dart';
import 'package:url_launcher/url_launcher.dart';

import '../diagnostics/debug_log.dart';
import '../providers/auto_update_preference.dart';
import '../providers/providers.dart';
import 'relaunch.dart';
import 'rpm_updater.dart';
import 'self_update/self_update_controller.dart';
import 'startup_screen.dart';
import 'startup_state.dart';
import 'update_check.dart';
import 'update_package_view.dart';

/// Replaces the running process with a fresh one, so an installed update is
/// the build actually in memory. Injectable; the real one is `relaunch.dart`,
/// whose child waits for this process to be gone before starting.
typedef Relaunch = Future<void> Function();

Future<void> _realRelaunch() async {
  await spawnRelaunch();
  exit(0);
}

/// The splash's whole update pass. [container] carries the providers the
/// splash renders from; every other parameter is a seam for tests.
Future<void> runStartupUpdates(
  ProviderContainer container, {
  CheckForClientUpdate check = checkForClientUpdate,
  RpmUpdater rpm = const RpmUpdater(),
  Relaunch relaunch = _realRelaunch,
  InstallFormat? format,
  String? currentVersion,
  bool? selfApplies,
}) async {
  if (!isDesktopHost || updateChecksDisabled()) return;
  try {
    final prefs = await container.read(preferencesProvider.future);
    if (!loadAutoUpdatePreference(prefs)) return;

    container.read(startupStatusProvider.notifier).state =
        'Checking for updates';
    final version =
        currentVersion ?? (await PackageInfo.fromPlatform()).version;
    final update = await check(currentVersion: version, format: format);
    if (update == null) return;

    if (update.format == InstallFormat.rpm) {
      await _installWithDnf(container, version, update, rpm, relaunch);
      return;
    }
    if (update.format == InstallFormat.tarball &&
        (selfApplies ?? selfApplyTarget() != null)) {
      await _installInPlace(container, version, update, relaunch);
      return;
    }
    await _offerManually(container, update);
  } catch (error) {
    container
        .read(debugLogProvider.notifier)
        .record('update', 'startup update pass failed: $error');
  } finally {
    container.read(startupPromptProvider.notifier).state = null;
  }
}

/// The rpm path: dnf does the install behind the system's own polkit prompt,
/// and the new files only become the running build after a relaunch, so this
/// relaunches straight into them.
///
/// It does not ask. This runs on the mini splash, before the client is up, so
/// there is no conversation to interrupt and nothing in flight to lose - the
/// old "Restart now / Later" prompt only ever stood between someone and the
/// app they had just opened, and "Later" left them on a build they had already
/// replaced on disk.
Future<void> _installWithDnf(
  ProviderContainer container,
  String currentVersion,
  ClientUpdate update,
  RpmUpdater rpm,
  Relaunch relaunch,
) async {
  container.read(startupStatusProvider.notifier).state =
      'Installing ${update.version}';
  final result = await rpm.apply(currentVersion: currentVersion);
  if (!result.ok) {
    container
        .read(debugLogProvider.notifier)
        .record('update', 'dnf could not install: ${result.detail}');
    await _offerManually(container, update);
    return;
  }

  container.read(startupStatusProvider.notifier).state =
      'Restarting into ${update.version}';
  await relaunch();
}

/// The per-user tarball path: install into a new version directory, then
/// relaunch into it. A failure lands in the persistent banner and the client
/// that is already installed starts as usual.
Future<void> _installInPlace(
  ProviderContainer container,
  String currentVersion,
  ClientUpdate update,
  Relaunch relaunch,
) async {
  container.read(startupStatusProvider.notifier).state =
      'Installing ${update.version}';
  final installed = await container
      .read(selfUpdateProvider)
      .install(currentVersion: currentVersion);
  if (installed == null) return;
  container.read(startupStatusProvider.notifier).state =
      'Restarting into $installed';
  await relaunch();
}

/// Every format dnf does not cover, and every dnf run that failed: say the
/// version is there and open the release, which is what decision 0020's
/// notifier already did. A package-managed install is told its package
/// manager is the way and only offered "Check GitHub", since the repo may lag. A version turned down here is not offered again
/// until something newer exists.
Future<void> _offerManually(
  ProviderContainer container,
  ClientUpdate update,
) async {
  final prefs = await container.read(preferencesProvider.future);
  if (updateWasDismissed(
    dismissed: prefs.getString(dismissedUpdateVersionKey),
    candidate: update.version,
  )) {
    return;
  }

  final answer = Completer<bool>();
  container.read(startupPromptProvider.notifier).state = StartupPrompt(
    title: 'Version ${update.version} is available',
    detail: updateActionHint(update.format),
    primaryLabel: isPackageManaged(update.format)
        ? 'Check GitHub'
        : 'Get update',
    onPrimary: () => answer.complete(true),
    secondaryLabel: 'Not now',
    onSecondary: () => answer.complete(false),
  );
  final accepted = await answer.future;
  container.read(startupPromptProvider.notifier).state = null;
  if (!accepted) {
    await prefs.setString(dismissedUpdateVersionKey, update.version);
    return;
  }
  final uri = Uri.tryParse(update.releaseUrl);
  if (uri != null) {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
