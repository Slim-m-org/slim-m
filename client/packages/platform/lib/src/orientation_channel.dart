// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Lets a phone rotate while a call's video is full screen, and nowhere else.
///
/// Phones are portrait-locked natively (`MainActivity.kt`, `AppDelegate.swift`,
/// decision 0058), so this asks the native side rather than calling
/// `SystemChrome`: restoring from Dart could not tell a locked phone from a
/// free Android tablet, and iOS needs the app delegate to open the ceiling.
library;

import 'package:flutter/services.dart';

const _channelName = 'top.npcserver.slimm/orientation';

/// A no-op wherever nothing answers this channel (desktop, the web, a tablet
/// that is never locked), so a caller never has to check the platform first.
class OrientationChannel {
  OrientationChannel({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName);

  final MethodChannel _channel;

  /// Whether the native side changed anything: true only on a portrait-locked
  /// phone, so a caller can skip work that only matters once rotation is real.
  Future<bool> allowLandscape(bool allowed) async {
    try {
      return await _channel.invokeMethod<bool>('allowLandscape', allowed) ??
          false;
    } catch (_) {
      return false;
    }
  }
}
