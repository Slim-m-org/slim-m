// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where a call's timer starts: the call's own age, not this device's.
///
/// The server reports how long the longest-present participant has been in
/// the room (`call_age_ms` on the voice roster), so two people in one call
/// read the same time and a reload does not restart it. Until that answer
/// lands, and wherever it never does, the timer falls back to when this
/// device connected.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import '../../../providers/providers.dart';

class VoiceCallClock {
  VoiceCallClock(this._ref, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  /// How long to leave a failed or unanswered roster read alone before asking again.
  static const retryAfter = Duration(seconds: 10);

  /// Longer than the whole auto-rejoin budget, so only one of those attempts can pick the clock back up.
  static const carryWindow = Duration(minutes: 10);

  final Ref _ref;
  final DateTime Function() _now;
  DateTime? _carried;
  DateTime? _heldAt;
  DateTime? _lastAsk;
  bool _anchored = false;

  /// Remembers [start] across an automatic rejoin; a drop nobody will rejoin forgets it.
  bool hold(DateTime? start, {required bool rejoinable}) {
    _carried = rejoinable ? start : null;
    _heldAt = _now();
    return start != null;
  }

  void forget() {
    _carried = null;
  }

  /// The start for a call that just connected: the one held across a rejoin, else now.
  DateTime beginHere() {
    final heldAt = _heldAt;
    final fresh = heldAt != null && _now().difference(heldAt) < carryWindow;
    final start = (fresh ? _carried : null) ?? _now();
    _carried = null;
    _anchored = false;
    _lastAsk = null;
    return start;
  }

  /// The server's start for [channelId]'s call, or null when it is not known yet.
  ///
  /// Asked again on a later call only while it has not been answered, and
  /// never more often than [retryAfter].
  Future<DateTime?> serverStart(String channelId) async {
    final lastAsk = _lastAsk;
    if (_anchored ||
        (lastAsk != null && _now().difference(lastAsk) < retryAfter)) {
      return null;
    }
    _lastAsk = _now();
    try {
      final roster = await _ref
          .read(apiProvider)
          .voiceRosterSnapshot(channelId);
      final age = roster.callAge;
      if (age == null) return null;
      _anchored = true;
      return _now().subtract(age);
    } on Object {
      return null;
    }
  }
}
