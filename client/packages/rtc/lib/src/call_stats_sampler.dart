// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Samples video stats on a timer, but only while somebody needs them.
///
/// A call with no video must pay nothing for this: the timers exist only while
/// the stats panel is listening, a viewer or sender holds the sampler, or
/// logging is on.
library;

import 'dart:async';

import 'call_stats.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

/// One track that can be sampled.
class CallStatsTarget {
  const CallStatsTarget({
    required this.identity,
    required this.name,
    required this.source,
    required this.local,
    required this.fetch,
  });

  final String identity;
  final String name;
  final CallStatsSource source;
  final bool local;
  final Future<List<StatsEntry>> Function() fetch;

  String get key =>
      statsTrackKey(local: local, identity: identity, source: source);
}

/// The latest sample for every track in the call.
typedef CallStatsSnapshot = List<VideoStatsSample>;

class CallStatsSampler {
  CallStatsSampler({
    required List<CallStatsTarget> Function() targets,
    void Function(String line)? log,
    void Function(VideoStatsSample sample)? onSample,
    DateTime Function()? clock,
    this.remoteEvery = const Duration(seconds: 2),
    this.localEvery = const Duration(seconds: 5),
    this.logEvery = const Duration(seconds: 30),
  })  : _targets = targets,
        _log = log,
        _onSample = onSample,
        _clock = clock ?? DateTime.now {
    _controller = StreamController<CallStatsSnapshot>.broadcast(
      onListen: _refreshTimers,
      onCancel: _refreshTimers,
    );
  }

  final List<CallStatsTarget> Function() _targets;
  final void Function(String line)? _log;
  final void Function(VideoStatsSample sample)? _onSample;
  final DateTime Function() _clock;
  final Duration remoteEvery;
  final Duration localEvery;

  /// How often one track's line reaches the log, unless [logging] asks for every sample.
  final Duration logEvery;

  late final StreamController<CallStatsSnapshot> _controller;
  final _latest = <String, VideoStatsSample>{};
  Timer? _remoteTimer;
  Timer? _localTimer;
  final _lastLoggedAt = <String, DateTime>{};
  bool _logging = false;
  bool _held = false;
  bool _disposed = false;

  /// Samples as they land. Listening is what starts the sampling.
  Stream<CallStatsSnapshot> get snapshots => _controller.stream;

  CallStatsSnapshot get latest => List.unmodifiable(_latest.values);

  bool get logging => _logging;

  /// Keeps sampling and printing one line per sample without a listener.
  void setLogging(bool on) {
    _logging = on;
    _refreshTimers();
  }

  bool get held => _held;

  /// Keeps sampling for as long as we publish video ourselves, with nobody watching.
  void setHeld(bool on) {
    if (_held == on) return;
    _held = on;
    _refreshTimers();
  }

  bool get running => _remoteTimer != null;

  void _refreshTimers() {
    final wanted = !_disposed && (_controller.hasListener || _logging || _held);
    if (wanted && !running) {
      _remoteTimer = Timer.periodic(remoteEvery, (_) => _tick(local: false));
      _localTimer = Timer.periodic(localEvery, (_) => _tick(local: true));
      unawaited(_tick(local: false));
      unawaited(_tick(local: true));
    } else if (!wanted && running) {
      _remoteTimer?.cancel();
      _localTimer?.cancel();
      _remoteTimer = null;
      _localTimer = null;
      _latest.clear();
      _lastLoggedAt.clear();
    }
  }

  final _inFlight = <bool>{};

  Future<void> _tick({required bool local}) async {
    if (!_inFlight.add(local)) return;
    try {
      final targets = _targets().where((t) => t.local == local).toList();
      for (final t in targets) {
        await _sample(t);
      }
      final live = {for (final t in targets) t.key};
      final stale = _latest.entries
          .where((e) => e.value.local == local && !live.contains(e.key))
          .map((e) => e.key)
          .toList();
      for (final key in stale) {
        _latest.remove(key);
        _lastLoggedAt.remove(key);
      }
      _emit();
    } finally {
      _inFlight.remove(local);
    }
  }

  Future<void> _sample(CallStatsTarget t) async {
    try {
      final entries = await t.fetch();
      if (!running) return;
      final key = t.key;
      final sample = parseVideoStats(
        entries,
        identity: t.identity,
        name: t.name,
        source: t.source,
        local: t.local,
        previous: _latest[key],
      );
      _latest[key] = sample;
      _onSample?.call(sample);
      if (_logDue(key)) _log?.call(statsLogLine(sample));
    } catch (error, stack) {
      AppLog.swallowed(
          LogTag.voice,
          'A video track ended before its stats could be read; skipping it',
          error,
          stack);
    }
  }

  bool _logDue(String key) {
    final now = _clock();
    final last = _lastLoggedAt[key];
    if (!_logging && last != null && now.difference(last) < logEvery) {
      return false;
    }
    _lastLoggedAt[key] = now;
    return true;
  }

  void _emit() {
    if (_disposed || !running || _controller.isClosed) return;
    _controller.add(latest);
  }

  Future<void> dispose() async {
    _disposed = true;
    _refreshTimers();
    await _controller.close();
  }
}
