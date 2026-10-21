// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Bridges the app lock's privacy shield to native code: `FLAG_SECURE` on
/// Android (blocks a screenshot, a screen recording, and the recent-apps
/// thumbnail) and a cover over the task-switcher snapshot on iOS. See
/// `MainActivity.kt` and `SceneDelegate.swift`/`AppLockWindowChannel.swift`
/// for the native halves.
///
/// Tied to the same preference as the biometric unlock prompt rather than a
/// second toggle: both exist for the identical threat this feature's whole
/// settings row describes - someone with a hold of the unlocked device
/// seeing slim-m's content - so a person who does not want one does not
/// want the other either.
library;

import 'package:flutter/services.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

import 'host_platform.dart';

const _channelName = 'top.npcserver.slimm/app_lock_window';

/// A no-op wherever nothing answers this channel - desktop and the web - so
/// a caller never has to check the platform before using it.
class AppLockWindowChannel {
  /// [supported] says whether this host has a native half; only Android and
  /// iOS do.
  AppLockWindowChannel({MethodChannel? channel, bool? supported})
      : _channel = channel ?? const MethodChannel(_channelName),
        _supported = supported ?? (isAndroidHost || isIOSHost);

  final MethodChannel _channel;
  final bool _supported;

  /// Best-effort: a missing native handler must not throw, or the one thing
  /// this call exists for - hiding message content - would instead crash
  /// the very toggle meant to protect it.
  Future<void> setPrivacyShield(bool enabled) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('setPrivacyShield', enabled);
    } catch (error, stack) {
      AppLog.swallowed(LogTag.auth,
          'Could not hide the window contents for the app lock', error, stack);
    }
  }
}
