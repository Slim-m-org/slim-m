// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Lets a phone rotate while a call's video is full screen, and nowhere else.
///
/// Phones are portrait-locked natively (`MainActivity.kt`, `AppDelegate.swift`,
/// decision 0058), so this asks the native side rather than calling
/// `SystemChrome`: restoring from Dart could not tell a locked phone from a
/// free Android tablet, and iOS needs the app delegate to open the ceiling.
library;

import 'package:flutter/services.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

import 'host_platform.dart';

const _channelName = 'top.npcserver.slimm/orientation';

/// A no-op wherever nothing answers this channel (desktop, the web, a tablet
/// that is never locked), so a caller never has to check the platform first.
class OrientationChannel {
  /// [supported] says whether this host has a native handler; only the phone
  /// platforms do.
  OrientationChannel({MethodChannel? channel, bool? supported})
      : _channel = channel ?? const MethodChannel(_channelName),
        _supported = supported ?? (isAndroidHost || isIOSHost);

  final MethodChannel _channel;
  final bool _supported;

  /// Whether the native side changed anything: true only on a portrait-locked
  /// phone, so a caller can skip work that only matters once rotation is real.
  Future<bool> allowLandscape(bool allowed) async {
    if (!_supported) return false;
    try {
      return await _channel.invokeMethod<bool>('allowLandscape', allowed) ??
          false;
    } catch (error, stack) {
      AppLog.swallowed(LogTag.platform,
          'Could not change the allowed screen orientation', error, stack);
      return false;
    }
  }
}
