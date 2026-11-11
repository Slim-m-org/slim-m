// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Google Play re-signs the app, so a release apk can never install over a
/// Play copy; Play delivers those updates and the apk self-updater stays out.
library;

import 'package:package_info_plus/package_info_plus.dart';
import 'package:slimm_platform/platform.dart' show isAndroidHost;

const playStoreInstaller = 'com.android.vending';

/// Whether [info] describes an Android copy installed by Google Play.
/// [onAndroid] is injectable because every test host is a desktop.
bool installedFromPlay(PackageInfo info, {bool? onAndroid}) =>
    (onAndroid ?? isAndroidHost) && info.installerStore == playStoreInstaller;
