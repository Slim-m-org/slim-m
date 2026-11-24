// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the too-old screen offers for each way this build reached the device,
/// and the two ways off the screen that do not need an update at all.
library;

import 'package:package_info_plus/package_info_plus.dart';
import 'package:slimm_platform/platform.dart';

import '../../../desktop/startup_screen.dart' show updateActionHint;
import '../../accounts/providers/account_host.dart';

/// Where a build that cannot self-update sends someone instead.
const releasesUrl = 'https://github.com/Slim-m-org/slim-m/releases';

const playListingUrl = 'market://details?id=top.npcserver.slimm';
const playListingWebUrl =
    'https://play.google.com/store/apps/details?id=top.npcserver.slimm';
const appStoreUrl = 'https://apps.apple.com/search?term=slim-m';

const _appStoreInstaller = 'com.apple';

/// The update step the too-old screen's primary button performs.
enum TooOldAction {
  dnf,
  reload,
  release,
  testFlight,
  appStore,
  play,
  apk,
  selfUpdate,
  none,
}

/// Whether [info] describes an iPhone copy that came from the App Store.
bool installedFromAppStore(PackageInfo info, {bool? onIOS}) =>
    (onIOS ?? isIOSHost) && info.installerStore == _appStoreInstaller;

TooOldAction tooOldActionFor({
  required bool isWeb,
  required InstallFormat format,
  bool fromPlay = false,
  bool fromAppStore = false,
  bool selfApplies = false,
}) {
  if (isWeb) return TooOldAction.reload;
  if (fromPlay) return TooOldAction.play;
  if (fromAppStore) return TooOldAction.appStore;
  return switch (format) {
    InstallFormat.rpm => TooOldAction.dnf,
    InstallFormat.flatpak || InstallFormat.deb => TooOldAction.none,
    InstallFormat.testFlight => TooOldAction.testFlight,
    InstallFormat.apk => TooOldAction.apk,
    InstallFormat.tarball when selfApplies => TooOldAction.selfUpdate,
    _ => TooOldAction.release,
  };
}

String tooOldHint(TooOldAction action, InstallFormat format) =>
    switch (action) {
      TooOldAction.reload => 'Reload to load the newest version.',
      TooOldAction.play => 'Update slim-m in Google Play.',
      TooOldAction.appStore => 'Update slim-m in the App Store.',
      TooOldAction.apk ||
      TooOldAction.selfUpdate => 'Download and install the new version here.',
      _ => updateActionHint(format),
    };

/// Puts another Space on screen, or opens the add flow when this is the only one.
Future<void> useAnotherSpace(AccountHost host) async {
  final here = host.active?.account?.origin;
  for (final runtime in host.accounts) {
    final origin = runtime.account!.origin;
    if (origin == here) continue;
    await host.switchTo(origin);
    return;
  }
  await host.beginAdd();
}

/// Ends the active Space's session, which also lifts the floor: it only blocks a signed-in client.
Future<void> signOutOfThisSpace(AccountHost host) async {
  final origin = host.active?.account?.origin;
  if (origin != null) await host.signOut(origin);
}
