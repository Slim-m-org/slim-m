// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Samples video stats on a timer, but only while somebody is looking.
///
/// A normal call must pay nothing for this: the timers exist only while the
/// stats panel is listening or console logging is on.
library;

import 'dart:async';

import 'call_stats.dart';

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
}

/// The latest sample for every track in the call.
typedef CallStatsSnapshot = List<VideoStatsSample>;

class CallStatsSampler {
  CallStatsSampler({
    required List<CallStatsTarget> Function() targets,
    void Function(String line)? log,
    this.remoteEvery = const Duration(seconds: 2),
    this.localEvery = const Duration(seconds: 5),
  })  : _targets = targets,
        _log = log {
    _controller = StreamController<CallStatsSnapshot>.broadcast(
      onListen: _refreshTimers,
      onCancel: _refreshTimers,
    );
  }

  final List<CallStatsTarget> Function() _targets;
  final void Function(String line)? _log;
  final Duration remoteEvery;
  final Duration localEvery;

  late final StreamController<CallStatsSnapshot> _controller;
  final _latest = <String, VideoStatsSample>{};
  Timer? _remoteTimer;
  Timer? _localTimer;
  bool _logging = false;
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

  bool get running => _remoteTimer != null;

  void _refreshTimers() {
    final wanted = !_disposed && (_controller.hasListener || _logging);
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
      final live = {for (final t in targets) _keyOf(t)};
      final stale = _latest.entries
          .where((e) => e.value.local == local && !live.contains(e.key))
          .map((e) => e.key)
          .toList();
      stale.forEach(_latest.remove);
      _emit();
    } finally {
      _inFlight.remove(local);
    }
  }

  Future<void> _sample(CallStatsTarget t) async {
    try {
      final entries = await t.fetch();
      if (!running) return;
      final key = _keyOf(t);
      final sample = parseVideoStats(
        entries,
        identity: t.identity,
        name: t.name,
        source: t.source,
        local: t.local,
        previous: _latest[key],
      );
      _latest[key] = sample;
      _log?.call(statsLogLine(sample));
    } catch (_) {
      // A track that went away between listing and reading is just skipped.
    }
  }

  String _keyOf(CallStatsTarget t) =>
      '${t.local ? 'out' : 'in'}/${t.identity}/${t.source.name}';

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
