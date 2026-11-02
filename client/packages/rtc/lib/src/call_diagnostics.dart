// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a bug report about a call needs, kept apart from the debug log so a
/// chatty log cannot push it out, and written as one block of plain text.
///
/// Holds only numbers the call already logged: no tokens, no URLs, no
/// addresses, no message content.
library;

import 'call_stats.dart';
import 'voice_health_summary.dart';

/// How many finished share summaries one call keeps.
const int kDiagnosticsSummaryCap = 12;

class CallDiagnostics {
  CallDiagnostics({DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  DateTime? _startedAt;
  DateTime? _endedAt;
  String? _minuteLine;
  TransportStats? _transport;
  final _healthSummary = <String>[];
  final _statsLines = <String, String>{};
  final _trackSummaries = <String>[];

  /// Whether a call is up right now.
  bool get active => _startedAt != null && _endedAt == null;

  /// Whether anything has been kept from this call or the last one.
  bool get hasCall => _startedAt != null;

  /// Starts a call; a reconnect inside the same call keeps what it has.
  void begin() {
    if (active) return;
    _startedAt = _clock();
    _endedAt = null;
    _minuteLine = null;
    _transport = null;
    _healthSummary.clear();
    _statsLines.clear();
    _trackSummaries.clear();
  }

  /// Ends the call but keeps its numbers until the next one begins.
  void end() {
    if (!active) return;
    _endedAt = _clock();
  }

  /// Files a line the voice health watch logged; any other line is ignored.
  void noteHealthLine(String line) {
    if (line.startsWith(kHealthMinutePrefix)) {
      _minuteLine = line;
    } else if (line.startsWith(kHealthSummaryPrefix)) {
      _healthSummary.add(line);
    }
  }

  void noteStats(VideoStatsSample sample) {
    _statsLines[sample.key] = statsLogLine(sample);
    _transport = sample.transport ?? _transport;
  }

  /// The path audio rides, read from an audio report when no video exists.
  void noteTransport(TransportStats? transport) {
    _transport = transport ?? _transport;
  }

  void noteTrackSummary(String line) {
    if (_trackSummaries.length >= kDiagnosticsSummaryCap) {
      _trackSummaries.removeAt(0);
    }
    _trackSummaries.add(line);
  }

  /// The block a person pastes into a report.
  ///
  /// [facts] are the lines about this install and its devices; [joinLine] is
  /// the last join's timings.
  String report({required Map<String, String> facts, String? joinLine}) {
    final out = <String>[
      'Call diagnostics',
      _callState(),
      for (final e in facts.entries) '${e.key}: ${e.value}',
      if (_transport != null) 'Network path: ${_path(_transport!)}',
      if (joinLine != null) joinLine,
      '',
      'Audio',
      _minuteLine ?? 'No once-a-minute audio line yet.',
      ..._healthSummary,
      '',
      'Video',
      if (_statsLines.isEmpty && _trackSummaries.isEmpty)
        'No video was sampled.',
      ..._statsLines.values,
      ..._trackSummaries,
    ];
    return out.join('\n');
  }

  String _callState() {
    final started = _startedAt;
    if (started == null) {
      return 'No call is active, and none has run in this session.';
    }
    final when = '${_clock().difference(started).inSeconds}s';
    if (active) return 'In a call for $when.';
    final length = _endedAt!.difference(started).inSeconds;
    return 'No call is active. Showing the last call, which ran ${length}s.';
  }
}

String _path(TransportStats t) {
  final rtt = t.rttMs == null ? '' : ' rtt=${t.rttMs!.round()}ms';
  final send = t.availableOutgoingBps == null
      ? ''
      : ' available=${(t.availableOutgoingBps! / 1e6).toStringAsFixed(2)}Mbps';
  return '${t.localType ?? '?'} to ${t.remoteType ?? '?'} over '
      '${t.protocol ?? '?'}${t.relayed ? ' (relayed)' : ''}$rtt$send';
}
