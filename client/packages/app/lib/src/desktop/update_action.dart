// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What "take the update" does on this install, shared by the title bar's
/// update chip and the window menu's Update item so the two can never
/// disagree about it.
///
/// On an rpm install with auto-update on, it restarts: the splash's own update
/// pass installs through dnf and relaunches into the new build. A per-user
/// tarball installs the update itself (`self_update/`) and restarts. Anywhere
/// else it opens the release page, because this app does not fake a
/// self-update the platform cannot do (decision 0020).
library;

import 'dart:async';

import 'package:flutter/widgets.dart' show BuildContext;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart';

import '../providers/auto_update_preference.dart';
import '../providers/providers.dart';
import '../providers/voice_controller.dart';
import 'desktop_window_port.dart';
import 'self_update/self_update_controller.dart';
import 'update_check.dart';
import 'update_package_view.dart';
import 'update_watch.dart';

/// What the update action does for an update on this install.
enum UpdateMenuAction {
  installAndRestart,
  restartToUpdate,
  packageManager,
  openRelease,
}

/// A package-managed install (rpm, deb, flatpak) cannot take the update from
/// GitHub and its repo can lag the release, so it is told how the package
/// manager gets it, with the release page as a secondary "Check GitHub".
///
/// Restart only where the splash will actually install on the way back up:
/// an rpm, with the auto-update preference answered yes. A per-user tarball
/// installs itself on tap ([selfApplies]) and restarts once [staged].
UpdateMenuAction updateMenuAction(
  ClientUpdate update, {
  bool? autoUpdate,
  bool selfApplies = false,
  String? staged,
}) {
  if (selfApplies) {
    return staged == update.version
        ? UpdateMenuAction.restartToUpdate
        : UpdateMenuAction.installAndRestart;
  }
  if (update.format == InstallFormat.rpm && autoUpdate == true) {
    return UpdateMenuAction.restartToUpdate;
  }
  return isPackageManaged(update.format)
      ? UpdateMenuAction.packageManager
      : UpdateMenuAction.openRelease;
}

/// The auto-update preference, or null while it is still being read.
final autoUpdatePreferenceProvider = FutureProvider<bool?>((ref) async {
  final prefs = await ref.watch(preferencesProvider.future);
  return loadAutoUpdatePreference(prefs);
});

/// The action for the update this session knows about, or null without one.
final updateActionProvider = Provider<UpdateMenuAction?>((ref) {
  final update = ref.watch(inSessionUpdateProvider);
  if (update == null) return null;
  return updateMenuAction(
    update,
    autoUpdate: ref.watch(autoUpdatePreferenceProvider).valueOrNull,
    selfApplies:
        ref.watch(selfApplyAvailableProvider) &&
        update.format == InstallFormat.tarball,
    staged: ref.watch(stagedUpdateVersionProvider),
  );
});

/// The label naming [action] and [update]'s version, for a menu row, a
/// tooltip and a screen reader alike.
String updateActionLabel(
  ClientUpdate update,
  UpdateMenuAction action, {
  required bool installing,
}) => switch (action) {
  UpdateMenuAction.installAndRestart when installing =>
    'Installing ${update.version}',
  UpdateMenuAction.installAndRestart => 'Install ${update.version}',
  UpdateMenuAction.restartToUpdate => 'Restart to update to ${update.version}',
  UpdateMenuAction.packageManager => packageManagerLabel(update),
  UpdateMenuAction.openRelease => 'Get update ${update.version}',
};

/// Performs [action]. A tarball install restarts straight away unless a call
/// is live; then the action turns into "Restart to update" and waits.
Future<void> runUpdateAction(
  WidgetRef ref, {
  required DesktopWindowPort port,
  required ClientUpdate update,
  required UpdateMenuAction action,
  required BuildContext context,
  required bool Function() isMounted,
}) async {
  switch (action) {
    case UpdateMenuAction.installAndRestart:
      final info = await ref.read(appInfoProvider.future);
      final version = await ref
          .read(selfUpdateProvider)
          .install(currentVersion: info.version);
      if (version == null || !isMounted()) return;
      if (ref.read(voiceControllerProvider).channelId != null) return;
      await port.relaunch();
    case UpdateMenuAction.restartToUpdate:
      await port.relaunch();
    case UpdateMenuAction.packageManager:
      await showUpdatePackageView(context, update: update);
    case UpdateMenuAction.openRelease:
      final uri = Uri.tryParse(update.releaseUrl);
      if (uri == null) return;
      await ref.read(releaseLauncherProvider)(uri);
  }
}
