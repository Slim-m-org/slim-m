// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The device name sent at sign-in, with a phone's model where the platform
/// gives one.
library;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;

import 'host_platform.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

/// [deviceDisplayName], upgraded on a real phone build (never in a test host,
/// where a platform channel would never answer) to the model the OS reports
/// ("iPhone", "Pixel 8"). Never throws: a plugin that cannot answer leaves the
/// fallback name.
Future<String> resolveDeviceName() async {
  if (!isIOSHost && !isAndroidHost) return deviceDisplayName;
  try {
    final plugin = DeviceInfoPlugin();
    final model = isIOSHost
        ? (await plugin.iosInfo).model
        : (await plugin.androidInfo).model;
    return composeDeviceName(
      defaultTargetPlatform,
      host: deviceHostName,
      model: model,
    );
  } catch (error, stack) {
    AppLog.swallowed(
        LogTag.platform, 'resolve device name failed, ignored', error, stack);
    return deviceDisplayName;
  }
}
