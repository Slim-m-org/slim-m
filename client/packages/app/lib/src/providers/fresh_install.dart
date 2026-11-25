// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Telling a first launch from a launch whose preferences could not be read.
///
/// The keychain outlives an iOS or macOS uninstall while the first-launch flag
/// does not, so an absent flag there means "reinstall: drop the leftover
/// secrets". Everywhere else the secrets die with the app, so an absent flag
/// beside stored secrets means the preferences were lost, and the secrets stay.
library;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;
import 'package:slimm_platform/platform.dart';

const _protectedDataChannel = MethodChannel(
  'top.npcserver.slimm/protected_data',
);

/// What this launch turned out to be.
enum FirstLaunchOutcome {
  /// The flag was set: an ordinary launch.
  returning,

  /// A fresh install; every leftover secret was cleared.
  wiped,

  /// The flag was lost but the secrets are this install's own, so they stay.
  keptSecrets,

  /// The device is not unlocked yet; nothing was touched.
  deferred,
}

/// The two platform facts the decision rests on, replaceable in tests.
class FirstLaunchEnvironment {
  const FirstLaunchEnvironment({
    required this.keychainOutlivesInstall,
    required this.protectedDataAvailable,
  });

  factory FirstLaunchEnvironment.host() => FirstLaunchEnvironment(
    keychainOutlivesInstall: isIOSHost || isMacOSHost,
    protectedDataAvailable: _hostProtectedDataAvailable,
  );

  final bool keychainOutlivesInstall;
  final Future<bool> Function() protectedDataAvailable;
}

final firstLaunchEnvironmentProvider = Provider<FirstLaunchEnvironment>(
  (ref) => FirstLaunchEnvironment.host(),
);

Future<bool> _hostProtectedDataAvailable() async {
  if (!isIOSHost) return true;
  try {
    return await _protectedDataChannel.invokeMethod<bool>('isAvailable') ??
        false;
  } on PlatformException catch (error, stack) {
    AppLog.swallowed(
      LogTag.auth,
      'Could not read data protection',
      error,
      stack,
    );
  } on MissingPluginException catch (error, stack) {
    AppLog.swallowed(
      LogTag.auth,
      'Could not read data protection',
      error,
      stack,
    );
  }
  return false;
}

/// Settles the first-launch flag, clearing [stores] only for a real fresh install.
///
/// Reads [probe] from the first store before deciding, so an unreadable
/// store throws to the caller instead of reading as empty.
Future<FirstLaunchOutcome> settleFirstLaunch({
  required SharedPreferences prefs,
  required String flagKey,
  required List<KeyStore> stores,
  required Iterable<KeyHandle> probe,
  required FirstLaunchEnvironment environment,
}) async {
  if (prefs.getBool(flagKey) == true) return FirstLaunchOutcome.returning;
  if (!await environment.protectedDataAvailable()) {
    return FirstLaunchOutcome.deferred;
  }
  var hasSecrets = false;
  for (final handle in probe) {
    if (await stores.first.read(handle) != null) hasSecrets = true;
  }
  if (hasSecrets && !environment.keychainOutlivesInstall) {
    await prefs.setBool(flagKey, true);
    return FirstLaunchOutcome.keptSecrets;
  }
  for (final store in stores) {
    await store.clear();
  }
  await prefs.setBool(flagKey, true);
  return FirstLaunchOutcome.wiped;
}
