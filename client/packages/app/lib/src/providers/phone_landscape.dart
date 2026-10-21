// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A portrait-locked phone may rotate only while a call's video or a canvas
/// tile is full screen (decisions 0058 and 0086); everything routed below that
/// view keeps its portrait size.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart';

final orientationChannelProvider = Provider<OrientationChannel>(
  (ref) => OrientationChannel(),
);

/// Set once the native side reports a portrait-locked phone, the only device
/// whose window can turn landscape while the shell must not follow it.
final portraitLockedPhoneProvider = StateProvider<bool>((ref) => false);

/// [data] as the routed app should see it: on a locked phone in landscape the
/// width and height swap back, so the shell never lays out as a wide window.
MediaQueryData keepPortraitShell(
  MediaQueryData data, {
  required bool lockedPhone,
}) {
  final size = data.size;
  if (!lockedPhone || size.width <= size.height) return data;
  return data.copyWith(size: Size(size.height, size.width));
}

/// Lets a locked phone rotate for as long as it is held, and locks it again on release.
///
/// Built where `ref` is still readable, since release also runs from `dispose`.
class PhoneLandscapeHold {
  PhoneLandscapeHold(this._channel, this._lockedPhone);

  final OrientationChannel _channel;
  final StateController<bool> _lockedPhone;
  bool _held = false;

  bool get held => _held;

  Future<void> enter() async {
    if (_held) return;
    _held = true;
    final lockedPhone = await _channel.allowLandscape(true);
    if (!lockedPhone || !_held) return;
    _lockedPhone.state = true;
  }

  void release() {
    if (!_held) return;
    _held = false;
    unawaited(_channel.allowLandscape(false));
  }
}
