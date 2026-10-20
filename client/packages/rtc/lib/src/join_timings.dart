// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// When each stage of one voice join happened, for a single debug-log line.
library;

/// The stages of a join, in the order a sequential join reaches them.
///
/// [connected] is when LiveKit's connect returns, which is after the signalling
/// socket is open and the primary peer connection is up, so it covers both.
/// [micPublished] covers opening the capture and publishing it, which the
/// SDK does in one call.
enum JoinStage {
  click,
  tokenRequested,
  tokenReceived,
  connectStarted,
  connected,
  micPublished,
  firstRemoteAudio,
}

/// A finished join: milliseconds from the click for every stage it reached.
class JoinSummary {
  const JoinSummary(this.millis);

  final Map<JoinStage, int> millis;

  bool get complete => millis.containsKey(JoinStage.firstRemoteAudio);

  /// One line, stages in order, so a log search finds every join the same way.
  String get line {
    final stages = [
      for (final stage in JoinStage.values)
        if (millis.containsKey(stage)) '${stage.name}=${millis[stage]}',
    ];
    return 'Join timings in ms from the click: ${stages.join(' ')}'
        '${complete ? '' : ' (ended before remote audio)'}';
  }
}

/// Collects the stage marks of the join in progress.
///
/// A mark outside a join, or a second mark of the same stage, is ignored, so a
/// reconnect or a roster event never rewrites an earlier join's numbers.
class JoinTimings {
  JoinTimings({Duration Function()? clock, this.onFinished})
      : _clock = clock ?? _stopwatchClock();

  /// Called once per join with its summary, the moment it ends.
  final void Function(JoinSummary summary)? onFinished;

  final Duration Function() _clock;
  final _marks = <JoinStage, Duration>{};
  bool _open = false;

  /// Whether a join is in progress, so a watcher can stop once it ends.
  bool get isOpen => _open;

  /// The most recent finished join, for tests and the diagnostics screen.
  JoinSummary? last;

  static Duration Function() _stopwatchClock() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  /// Starts a join at the click, closing the previous one if it never ended.
  void begin() {
    finish();
    _marks.clear();
    _open = true;
    mark(JoinStage.click);
  }

  void mark(JoinStage stage) {
    if (!_open) return;
    _marks.putIfAbsent(stage, _clock);
    if (stage == JoinStage.firstRemoteAudio) finish();
  }

  /// Ends the join in progress; a join that never heard anyone is reported as it stood.
  void finish() {
    if (!_open) return;
    _open = false;
    final start = _marks[JoinStage.click] ?? Duration.zero;
    final summary = JoinSummary({
      for (final entry in _marks.entries)
        entry.key: (entry.value - start).inMilliseconds,
    });
    last = summary;
    onFinished?.call(summary);
  }
}
