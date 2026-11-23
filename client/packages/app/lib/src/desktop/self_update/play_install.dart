// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Google Play re-signs the app, so a release apk can never install over a
/// Play copy; Play delivers those updates and the apk self-updater stays out.
library;

import 'package:package_info_plus/package_info_plus.dart';
import 'package:slimm_platform/platform.dart' show isAndroidHost;

const playStoreInstaller = 'com.android.vending';

/// Set for the appbundle, which only ever goes to Google Play; a const so the
/// sideload apk updater is compiled out of that build.
const bool playBuild = bool.fromEnvironment('SLIMM_PLAY_BUILD');

/// Whether [info] describes an Android copy that Google Play updates.
/// [onAndroid] and [isPlayBuild] are injectable because every test host is a
/// desktop build without the define.
bool installedFromPlay(
  PackageInfo info, {
  bool? onAndroid,
  bool isPlayBuild = playBuild,
}) =>
    (onAndroid ?? isAndroidHost) &&
    (isPlayBuild || info.installerStore == playStoreInstaller);
