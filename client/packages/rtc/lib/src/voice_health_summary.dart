// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a call's audio looked like, as numbers and as the log lines that carry them.
library;

import 'audio_stats.dart' show kDefaultAudioClockRate;
import 'mic_recovery.dart' show senderLevelToDb;
import 'voice_health_window.dart';

/// Median and tail of each measure over a run of intervals.
class HealthStats {
  const HealthStats({
    required this.seconds,
    this.concealP50,
    this.concealP95,
    this.bufferP50,
    this.bufferP95,
    this.jitterP50,
    this.jitterP95,
    this.rttP50,
    this.rttP95,
    this.lossP50,
    this.lossP95,
    this.concealmentEvents = 0,
    this.discardedPackets,
    this.acceleratedSamples,
    this.deceleratedSamples,
    this.silentConcealedSamples,
    this.echoLossP50,
    this.echoEnhancementP50,
  });

  factory HealthStats.of(List<HealthInterval> intervals) {
    Iterable<double> pick(double? Function(HealthInterval) f) =>
        intervals.map(f).whereType<double>();
    double? at(double? Function(HealthInterval) f, double q) =>
        percentile(pick(f), q);
    return HealthStats(
      seconds: intervals.fold(0.0, (s, e) => s + e.seconds),
      concealP50: at((e) => e.concealShare, 0.5),
      concealP95: at((e) => e.concealShare, 0.95),
      bufferP50: at((e) => e.bufferMs, 0.5),
      bufferP95: at((e) => e.bufferMs, 0.95),
      jitterP50: at((e) => e.jitterMs, 0.5),
      jitterP95: at((e) => e.jitterMs, 0.95),
      rttP50: at((e) => e.rttMs, 0.5),
      rttP95: at((e) => e.rttMs, 0.95),
      lossP50: at((e) => e.lossShare, 0.5),
      lossP95: at((e) => e.lossShare, 0.95),
      concealmentEvents: intervals.fold(0.0, (s, e) => s + e.concealmentEvents),
      discardedPackets: sumOrNull(intervals.map((e) => e.discardedPackets)),
      acceleratedSamples: sumOrNull(intervals.map((e) => e.acceleratedSamples)),
      deceleratedSamples: sumOrNull(intervals.map((e) => e.deceleratedSamples)),
      silentConcealedSamples:
          sumOrNull(intervals.map((e) => e.silentConcealedSamples)),
      echoLossP50: at((e) => e.echoReturnLossDb, 0.5),
      echoEnhancementP50: at((e) => e.echoEnhancementDb, 0.5),
    );
  }

  final double seconds;

  /// Shares are 0 to 1; delays are milliseconds.
  final double? concealP50;
  final double? concealP95;
  final double? bufferP50;
  final double? bufferP95;
  final double? jitterP50;
  final double? jitterP95;
  final double? rttP50;
  final double? rttP95;
  final double? lossP50;
  final double? lossP95;
  final double concealmentEvents;

  /// Totals over the run, null where the platform reports none; samples are at the Opus clock.
  final double? discardedPackets;
  final double? acceleratedSamples;
  final double? deceleratedSamples;
  final double? silentConcealedSamples;

  /// Our own echo canceller, dB; null when the platform reports none.
  final double? echoLossP50;
  final double? echoEnhancementP50;
}

class CallHealthSummary {
  const CallHealthSummary({
    required this.endedAt,
    required this.remote,
    required this.peers,
    this.local,
  });

  factory CallHealthSummary.of({
    required DateTime endedAt,
    required Map<String, List<HealthInterval>> remote,
    List<HealthInterval>? local,
  }) =>
      CallHealthSummary(
        endedAt: endedAt,
        remote: HealthStats.of([for (final h in remote.values) ...h]),
        peers: {for (final e in remote.entries) e.key: HealthStats.of(e.value)},
        local: local == null || local.isEmpty ? null : HealthStats.of(local),
      );

  final DateTime endedAt;

  /// Every remote person's intervals pooled.
  final HealthStats remote;
  final Map<String, HealthStats> peers;
  final HealthStats? local;
}

/// A named stream's recent window, for the once-a-minute line.
class NamedWindow {
  const NamedWindow(this.name, this.window, {this.local = false});

  final String name;
  final HealthWindow window;
  final bool local;
}

String _pct(double? v) => v == null ? '?' : '${(v * 100).toStringAsFixed(1)}%';
String _ms(double? v) => v == null ? '?' : '${v.round()}ms';
String _db(double? level) =>
    level == null ? '?' : '${senderLevelToDb(level).round()}dB';
String _echoDb(double v) => '${v.round()}dB';

/// Samples at the Opus clock as milliseconds.
String _sampleMs(double samples) =>
    '${(samples / (kDefaultAudioClockRate / 1000)).round()}ms';

/// The jitter buffer's other work: what the platform reports, and with
/// [always] false only what is above zero.
String _adaptation(
  ({
    double? discarded,
    double? accelerated,
    double? decelerated,
    double? silent
  }) v, {
  bool always = false,
}) {
  bool show(double? n) => n != null && (always || n > 0);
  final parts = [
    if (show(v.discarded)) 'discarded=${v.discarded!.round()}',
    if (show(v.accelerated)) 'accel=${_sampleMs(v.accelerated!)}',
    if (show(v.decelerated)) 'decel=${_sampleMs(v.decelerated!)}',
    if (show(v.silent)) 'silent=${_sampleMs(v.silent!)}',
  ];
  return parts.isEmpty ? '' : ' ${parts.join(' ')}';
}

String _echoParts(double? loss, double? enhancement) => [
      if (loss != null) ' erl=${_echoDb(loss)}',
      if (enhancement != null) ' erle=${_echoDb(enhancement)}',
    ].join();

/// One line for the whole call so far: every person's last minute.
String? minuteLine(List<NamedWindow> windows) {
  if (windows.isEmpty) return null;
  final parts = [for (final w in windows) _windowPart(w)];
  return '[voice-health] last 60s | ${parts.join(' | ')}';
}

String _windowPart(NamedWindow w) {
  final win = w.window;
  if (w.local) {
    return '${w.name}: sent=${win.kbps?.round() ?? '?'}kbps '
        'level=${_db(win.peakLevel)} rtt=${_ms(win.rttMs)} '
        'loss=${_pct(win.lossShare)}'
        '${_echoParts(win.echoReturnLossDb, win.echoEnhancementDb)}';
  }
  return '${w.name}: conceal=${_pct(win.concealShare)} '
      'events=${win.concealmentEvents.round()} jitter=${_ms(win.jitterMs)} '
      'buffer=${_ms(win.bufferMs)} loss=${_pct(win.lossShare)} '
      'level=${_db(win.peakLevel)} rtt=${_ms(win.rttMs)}'
      '${_adaptation((
        discarded: win.discardedPackets,
        accelerated: win.acceleratedSamples,
        decelerated: win.deceleratedSamples,
        silent: win.silentConcealedSamples
      ))}';
}

/// The lines logged when a call ends: everyone pooled, then each person.
List<String> summaryLines(CallHealthSummary summary) => [
      if (summary.peers.isNotEmpty)
        '[voice-health] call summary ${_stats(summary.remote, pooled: true)}',
      for (final e in summary.peers.entries)
        '[voice-health] call summary ${e.key}: ${_stats(e.value)}',
      if (summary.local case final local?)
        '[voice-health] call summary you: ${_statsLocal(local)}',
    ];

String _stats(HealthStats s, {bool pooled = false}) =>
    'over ${s.seconds.round()}s '
    'conceal p50=${_pct(s.concealP50)} p95=${_pct(s.concealP95)} '
    'events=${s.concealmentEvents.round()} '
    'buffer p50=${_ms(s.bufferP50)} p95=${_ms(s.bufferP95)} '
    'jitter p50=${_ms(s.jitterP50)} p95=${_ms(s.jitterP95)} '
    'rtt p50=${_ms(s.rttP50)} p95=${_ms(s.rttP95)} '
    'loss p50=${_pct(s.lossP50)} p95=${_pct(s.lossP95)}'
    '${_adaptation((
          discarded: s.discardedPackets,
          accelerated: s.acceleratedSamples,
          decelerated: s.deceleratedSamples,
          silent: s.silentConcealedSamples
        ), always: pooled)}';

String _statsLocal(HealthStats s) => 'over ${s.seconds.round()}s '
    'rtt p50=${_ms(s.rttP50)} p95=${_ms(s.rttP95)} '
    'loss p50=${_pct(s.lossP50)} p95=${_pct(s.lossP95)}'
    '${_echoParts(s.echoLossP50, s.echoEnhancementP50)}';
