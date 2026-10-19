// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a call's audio looked like, as numbers and as the log lines that carry them.
library;

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
        'loss=${_pct(win.lossShare)}';
  }
  return '${w.name}: conceal=${_pct(win.concealShare)} '
      'events=${win.concealmentEvents.round()} jitter=${_ms(win.jitterMs)} '
      'buffer=${_ms(win.bufferMs)} loss=${_pct(win.lossShare)} '
      'level=${_db(win.peakLevel)} rtt=${_ms(win.rttMs)}';
}

/// The lines logged when a call ends: everyone pooled, then each person.
List<String> summaryLines(CallHealthSummary summary) => [
      '[voice-health] call summary ${_stats(summary.remote)}',
      for (final e in summary.peers.entries)
        '[voice-health] call summary ${e.key}: ${_stats(e.value)}',
      if (summary.local case final local?)
        '[voice-health] call summary you: ${_statsLocal(local)}',
    ];

String _stats(HealthStats s) => 'over ${s.seconds.round()}s '
    'conceal p50=${_pct(s.concealP50)} p95=${_pct(s.concealP95)} '
    'events=${s.concealmentEvents.round()} '
    'buffer p50=${_ms(s.bufferP50)} p95=${_ms(s.bufferP95)} '
    'jitter p50=${_ms(s.jitterP50)} p95=${_ms(s.jitterP95)} '
    'rtt p50=${_ms(s.rttP50)} p95=${_ms(s.rttP95)} '
    'loss p50=${_pct(s.lossP50)} p95=${_pct(s.lossP95)}';

String _statsLocal(HealthStats s) => 'over ${s.seconds.round()}s '
    'rtt p50=${_ms(s.rttP50)} p95=${_ms(s.rttP95)} '
    'loss p50=${_pct(s.lossP50)} p95=${_pct(s.lossP95)}';
