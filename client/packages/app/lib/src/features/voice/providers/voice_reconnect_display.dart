// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Turns the SDK's own reconnect, as the session reports it, into the banner's flag.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'voice_state_access.dart';

/// How long a reconnect must last before the banner shows, so a resume that
/// finishes in a few hundred milliseconds never flashes it.
const Duration kReconnectBannerDelay = Duration(seconds: 2);

class VoiceReconnectDisplay {
  VoiceReconnectDisplay(
    this._reconnecting,
    this._access, {
    Duration delay = kReconnectBannerDelay,
  }) : _delay = delay {
    _reconnecting.addListener(_changed);
  }

  final ValueListenable<bool> _reconnecting;
  final VoiceStateAccess _access;
  final Duration _delay;
  Timer? _pending;

  void _changed() {
    if (!_reconnecting.value) {
      _pending?.cancel();
      _pending = null;
      if (_access.state.reconnecting) {
        _access.state = _access.state.copyWith(reconnecting: false);
      }
      return;
    }
    _pending ??= Timer(_delay, () {
      _pending = null;
      if (!_reconnecting.value) return;
      _access.state = _access.state.copyWith(reconnecting: true);
    });
  }

  void dispose() {
    _pending?.cancel();
    _reconnecting.removeListener(_changed);
  }
}
