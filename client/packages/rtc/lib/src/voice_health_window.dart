// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One sampling interval of a call's audio, and the rolling windows over them.
library;

import 'dart:collection';

/// What changed between two reads of one stream.
class HealthInterval {
  const HealthInterval({
    required this.seconds,
    this.concealedSamples = 0,
    this.samples = 0,
    this.concealmentEvents = 0,
    this.lostPackets = 0,
    this.receivedPackets = 0,
    this.jitterMs,
    this.bufferMs,
    this.audioLevel,
    this.rttMs,
    this.kbps,
  });

  final double seconds;
  final double concealedSamples;
  final double samples;
  final double concealmentEvents;
  final double lostPackets;
  final double receivedPackets;
  final double? jitterMs;

  /// Mean time audio sat in the jitter buffer during this interval.
  final double? bufferMs;
  final double? audioLevel;
  final double? rttMs;
  final double? kbps;

  double? get concealShare => samples > 0 ? concealedSamples / samples : null;

  double? get lossShare {
    final total = lostPackets + receivedPackets;
    return total > 0 ? lostPackets / total : null;
  }
}

/// The last stretch of a stream, weighted by how long each interval was, so a
/// short noisy interval cannot outvote a long clean one.
class HealthWindow {
  HealthWindow(this.span);

  /// Intervals older than this fall out, measured in the intervals' own seconds.
  final Duration span;

  final _entries = Queue<HealthInterval>();

  bool get isEmpty => _entries.isEmpty;
  double get seconds => _entries.fold(0.0, (s, e) => s + e.seconds);

  void add(HealthInterval interval) {
    _entries.addLast(interval);
    final limit = span.inMilliseconds / 1000;
    while (_entries.length > 1 && seconds - _entries.first.seconds >= limit) {
      _entries.removeFirst();
    }
  }

  void clear() => _entries.clear();

  double? get concealShare {
    final samples = _entries.fold(0.0, (s, e) => s + e.samples);
    if (samples <= 0) return null;
    return _entries.fold(0.0, (s, e) => s + e.concealedSamples) / samples;
  }

  double? get lossShare {
    final lost = _entries.fold(0.0, (s, e) => s + e.lostPackets);
    final total = lost + _entries.fold(0.0, (s, e) => s + e.receivedPackets);
    return total > 0 ? lost / total : null;
  }

  double get concealmentEvents =>
      _entries.fold(0.0, (s, e) => s + e.concealmentEvents);

  double? get jitterMs => _mean((e) => e.jitterMs);
  double? get bufferMs => _mean((e) => e.bufferMs);
  double? get rttMs => _mean((e) => e.rttMs);
  double? get kbps => _mean((e) => e.kbps);
  double? get peakLevel => _entries
      .map((e) => e.audioLevel)
      .whereType<double>()
      .fold<double?>(null, (m, v) => m == null || v > m ? v : m);

  double? _mean(double? Function(HealthInterval) pick) {
    var total = 0.0;
    var weight = 0.0;
    for (final e in _entries) {
      final v = pick(e);
      if (v == null) continue;
      total += v * e.seconds;
      weight += e.seconds;
    }
    return weight > 0 ? total / weight : null;
  }
}

/// The value at [fraction] (0 to 1) of [values], by nearest rank; null when empty.
double? percentile(Iterable<double> values, double fraction) {
  final sorted = values.toList()..sort();
  if (sorted.isEmpty) return null;
  final rank = (fraction * sorted.length).ceil().clamp(1, sorted.length);
  return sorted[rank - 1];
}
