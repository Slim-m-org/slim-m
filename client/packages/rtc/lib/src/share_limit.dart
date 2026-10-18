// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Noticing that our own screen share is being held back, so the sharer is told
/// instead of finding out from a viewer.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'call_stats.dart';
import 'call_stats_sampler.dart';

/// What the encoder says is holding our share back.
enum ShareLimit { cpu, bandwidth }

/// The limit shown by a set of outgoing layers, or null when nothing is held back.
ShareLimit? shareLimitOf(VideoStatsSample sample) {
  final reasons = {
    for (final s in sample.streams)
      if (s.active != false) s.limitationReason,
  };
  if (reasons.contains('cpu')) return ShareLimit.cpu;
  if (reasons.contains('bandwidth')) return ShareLimit.bandwidth;
  return null;
}

/// Raises [limit] once per share, after the same limit shows in
/// [confirmSamples] outgoing samples in a row.
///
/// Samples only while a share is up, so a call without one polls nothing.
class ShareLimitMonitor {
  ShareLimitMonitor(this._stats, {this.confirmSamples = 2});

  final CallStatsSampler _stats;
  final int confirmSamples;

  /// Non-null from the moment a limit is confirmed until it is dismissed or the share ends.
  final limit = ValueNotifier<ShareLimit?>(null);

  StreamSubscription<CallStatsSnapshot>? _subscription;
  VideoStatsSample? _lastSample;
  ShareLimit? _streakLimit;
  int _streak = 0;
  bool _told = false;

  /// Starts or stops watching to match whether we are publishing a share.
  void sync({required bool sharing}) {
    if (sharing && _subscription == null) {
      _subscription = _stats.snapshots.listen(_onSnapshot);
    } else if (!sharing && _subscription != null) {
      stop();
    }
  }

  /// Hides the banner without letting it come back for this share.
  void dismiss() => limit.value = null;

  void stop() {
    unawaited(_subscription?.cancel());
    _subscription = null;
    _lastSample = null;
    _streakLimit = null;
    _streak = 0;
    _told = false;
    limit.value = null;
  }

  void _onSnapshot(CallStatsSnapshot snapshot) {
    final sample = snapshot
        .where((s) => s.local && s.source == CallStatsSource.screenShare)
        .firstOrNull;
    if (sample == null || identical(sample, _lastSample)) return;
    _lastSample = sample;
    final seen = shareLimitOf(sample);
    _streak = seen != null && seen == _streakLimit ? _streak + 1 : 1;
    _streakLimit = seen;
    if (seen != null && !_told && _streak >= confirmSamples) {
      _told = true;
      limit.value = seen;
    }
  }
}
