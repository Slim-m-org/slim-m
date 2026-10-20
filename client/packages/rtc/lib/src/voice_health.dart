// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How a call's audio is doing, per person, from the counters `getStats` keeps.
///
/// Thresholds and their basis are in `docs/voice-health.md`.
library;

import 'package:flutter/foundation.dart';

import 'audio_stats.dart';
import 'voice_health_summary.dart';
import 'voice_health_window.dart';

/// Concealed share of a stream at which it is heard as static.
const double kPoorConcealmentShare = 0.05;

/// Concealed share a poor stream must fall under before it counts as recovered.
const double kRecoveredConcealmentShare = 0.03;

/// Mean jitter buffer at which delay is noticeable (plan target at 50 ms jitter).
const double kPoorJitterBufferMs = 160;
const double kRecoveredJitterBufferMs = 120;

/// Round trip at which conversation breaks down (ITU-T G.114 planning ceiling).
const double kPoorRttMs = 400;
const double kRecoveredRttMs = 300;

/// Loss our own audio suffers on the way out, as the far end reports it.
const double kPoorSendLossShare = 0.05;
const double kRecoveredSendLossShare = 0.03;

/// How long a stream must stay bad before the hint shows.
const Duration kPoorSustain = Duration(seconds: 5);

/// How long it must stay clearly good before the hint goes.
const Duration kRecoverSustain = Duration(seconds: 10);

/// How far back the once-a-minute line and its window look.
const Duration kHealthLogEvery = Duration(seconds: 60);

/// The longest history kept per stream for the end-of-call summary.
const int kHealthHistoryCap = 2880;

/// Samples land a little short of their nominal interval, so a run counts a bit early.
const double _intervalTolerance = 0.5;

/// Turns a run of good or bad intervals into a hint that does not flicker.
class QualityGate {
  bool poor = false;
  double _badFor = 0;
  double _goodFor = 0;

  /// Feeds one interval; true when [poor] changed. An interval that is neither
  /// bad nor clear breaks both runs.
  bool update({
    required double seconds,
    required bool bad,
    required bool clear,
  }) {
    _badFor = bad ? _badFor + seconds : 0;
    _goodFor = clear ? _goodFor + seconds : 0;
    if (!poor &&
        _badFor >= kPoorSustain.inMilliseconds / 1000 - _intervalTolerance) {
      poor = true;
      return true;
    }
    if (poor &&
        _goodFor >=
            kRecoverSustain.inMilliseconds / 1000 - _intervalTolerance) {
      poor = false;
      return true;
    }
    return false;
  }

  void reset() {
    poor = false;
    _badFor = 0;
    _goodFor = 0;
  }
}

class _Stream {
  _Stream(this.name);

  String name;
  AudioReceiveSample? previousReceive;
  AudioSendSample? previousSend;
  final window = HealthWindow(kHealthLogEvery);
  final history = <HealthInterval>[];
  final gate = QualityGate();
  bool present = true;

  /// Drops what the live reading and hint were built from, keeping the history.
  void forget() {
    previousReceive = null;
    gate.reset();
    window.clear();
  }

  void add(HealthInterval interval) {
    window.add(interval);
    history.add(interval);
    if (history.length > kHealthHistoryCap) history.removeAt(0);
  }
}

class VoiceHealth {
  VoiceHealth({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final _remote = <String, _Stream>{};
  _Stream? _local;
  String? _localId;
  DateTime? _lastLogAt;

  /// Identities whose connection is bad right now; empty while all is well.
  final ValueNotifier<Set<String>> poorConnections = ValueNotifier(const {});

  /// The previous call's summary, kept until the next call ends.
  final ValueNotifier<CallHealthSummary?> lastCall = ValueNotifier(null);

  bool get hasData =>
      _remote.values.any((s) => s.history.isNotEmpty) ||
      (_local?.history.isNotEmpty ?? false);

  void observeRemote(String id, String name, AudioReceiveSample now) {
    final stream = _remote.putIfAbsent(id, () => _Stream(name))
      ..name = name
      ..present = true;
    final before = stream.previousReceive;
    if (before == null || _wentBackwards(before, now)) {
      stream.previousReceive = now;
      return;
    }
    final interval = _receiveInterval(before, now);
    if (interval == null) return;
    stream.previousReceive = now;
    stream.add(interval);
    final share = interval.concealShare;
    final buffer = interval.bufferMs;
    _gate(
      stream,
      interval.seconds,
      bad: (share ?? 0) >= kPoorConcealmentShare ||
          (buffer ?? 0) >= kPoorJitterBufferMs,
      clear: (share ?? 0) < kRecoveredConcealmentShare &&
          (buffer ?? 0) < kRecoveredJitterBufferMs,
    );
  }

  void observeLocal(String id, AudioSendSample now) {
    final stream = _local ??= _Stream(id);
    _localId = id;
    final before = stream.previousSend;
    if (before == null || _sentBackwards(before, now)) {
      stream.previousSend = now;
      return;
    }
    final interval = _sendInterval(before, now);
    if (interval == null) return;
    stream.previousSend = now;
    stream.add(interval);
    final loss = interval.lossShare;
    final rtt = interval.rttMs;
    _gate(
      stream,
      interval.seconds,
      bad: (rtt ?? 0) >= kPoorRttMs || (loss ?? 0) >= kPoorSendLossShare,
      clear:
          (rtt ?? 0) < kRecoveredRttMs && (loss ?? 0) < kRecoveredSendLossShare,
    );
  }

  /// Forgets what a stream last read, so a gap (muted, resubscribed) is not
  /// counted as concealment when it comes back. A stream with no audio has no
  /// connection to flag, so its hint goes too.
  void skip(String id) {
    final stream = _remote[id];
    if (stream == null) return;
    stream.forget();
    _publish();
  }

  /// Drops people no longer in the call from the hint, keeping their history.
  void retain(Set<String> ids) {
    for (final entry in _remote.entries) {
      if (ids.contains(entry.key)) continue;
      entry.value
        ..present = false
        ..forget();
    }
    _publish();
  }

  /// The once-a-minute line, or null when none is due or there is nothing to say.
  String? takeMinuteLine() {
    final now = _clock();
    final last = _lastLogAt ??= now;
    if (now.difference(last) < kHealthLogEvery) return null;
    _lastLogAt = now;
    return minuteLine(_windows());
  }

  /// Ends the call: the summary lines for the log, and the summary kept for
  /// the Troubleshooting page. Empty when nothing was sampled.
  List<String> finish() {
    if (!hasData) {
      reset();
      return const [];
    }
    final summary = CallHealthSummary.of(
      endedAt: _clock(),
      remote: _historiesByLabel(),
      local: _local?.history,
    );
    // Sitting alone must not erase the numbers of the call before.
    if (summary.peers.isNotEmpty || lastCall.value == null) {
      lastCall.value = summary;
    }
    reset();
    return summaryLines(summary);
  }

  /// Each person's history under their name, or name and id when two share one.
  Map<String, List<HealthInterval>> _historiesByLabel() {
    final withData = _remote.entries.where((e) => e.value.history.isNotEmpty);
    final names = <String, int>{};
    for (final e in withData) {
      names.update(e.value.name, (n) => n + 1, ifAbsent: () => 1);
    }
    return {
      for (final e in withData)
        names[e.value.name]! > 1 ? '${e.value.name} (${e.key})' : e.value.name:
            e.value.history,
    };
  }

  void reset() {
    _remote.clear();
    _local = null;
    _localId = null;
    _lastLogAt = null;
    _publish();
  }

  void dispose() {
    poorConnections.dispose();
    lastCall.dispose();
  }

  List<NamedWindow> _windows() => [
        for (final s in _remote.values)
          if (s.present && !s.window.isEmpty) NamedWindow(s.name, s.window),
        if (_local case final l? when !l.window.isEmpty)
          NamedWindow('you', l.window, local: true),
      ];

  void _gate(
    _Stream stream,
    double seconds, {
    required bool bad,
    required bool clear,
  }) {
    final changed =
        stream.gate.update(seconds: seconds, bad: bad, clear: clear);
    if (changed) _publish();
  }

  void _publish() {
    final poor = <String>{
      for (final e in _remote.entries)
        if (e.value.present && e.value.gate.poor) e.key,
      if (_localId != null && (_local?.gate.poor ?? false)) _localId!,
    };
    if (!setEquals(poor, poorConnections.value)) poorConnections.value = poor;
  }
}

bool _wentBackwards(AudioReceiveSample before, AudioReceiveSample now) =>
    (now.samples ?? 0) < (before.samples ?? 0);

bool _sentBackwards(AudioSendSample before, AudioSendSample now) =>
    (now.packetsSent ?? 0) < (before.packetsSent ?? 0);

HealthInterval? _receiveInterval(
  AudioReceiveSample before,
  AudioReceiveSample now,
) {
  final a = before.samples;
  final b = now.samples;
  if (a == null || b == null) return null;
  final clock = (now.clockRate ?? kDefaultAudioClockRate).toDouble();
  final samples = b - a;
  if (samples / clock < 1) return null;
  double delta(num? x, num? y) => ((y ?? 0) - (x ?? 0)).toDouble();
  final delay = delta(before.jitterBufferDelay, now.jitterBufferDelay);
  final emitted =
      delta(before.jitterBufferEmittedCount, now.jitterBufferEmittedCount);
  final per = now.jitterBufferEmittedCount == null ? samples : emitted;
  final jitter = now.jitterSeconds;
  return HealthInterval(
    seconds: samples / clock,
    concealedSamples: delta(before.concealedSamples, now.concealedSamples),
    samples: samples,
    concealmentEvents: delta(before.concealmentEvents, now.concealmentEvents),
    lostPackets: delta(before.packetsLost, now.packetsLost).clamp(0, 1e12),
    receivedPackets: delta(before.packetsReceived, now.packetsReceived),
    jitterMs: jitter == null ? null : jitter * 1000,
    bufferMs:
        now.jitterBufferDelay == null || per <= 0 ? null : delay / per * 1000,
    audioLevel: now.audioLevel?.toDouble(),
    rttMs: now.rttMs,
  );
}

HealthInterval? _sendInterval(AudioSendSample before, AudioSendSample now) {
  final t0 = before.timestampMs;
  final t1 = now.timestampMs;
  if (t0 == null || t1 == null) return null;
  final seconds = (t1 - t0) / 1000;
  if (seconds < 1) return null;
  double delta(num? x, num? y) => ((y ?? 0) - (x ?? 0)).toDouble();
  final jitter = now.jitterSeconds;
  return HealthInterval(
    seconds: seconds,
    receivedPackets: delta(before.packetsSent, now.packetsSent),
    lostPackets: delta(before.packetsLost, now.packetsLost).clamp(0, 1e12),
    kbps: delta(before.bytesSent, now.bytesSent) * 8 / seconds / 1000,
    jitterMs: jitter == null ? null : jitter * 1000,
    audioLevel: now.audioLevel?.toDouble(),
    rttMs: now.rttMs,
  );
}
