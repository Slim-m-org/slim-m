// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Folding the same person's repeated joins into one row of the "What
/// happened" list: a flaky connection reads "Riley joined ×6", not six lines.
/// Pure, so the folding is tested without widgets.
library;

import 'call_timeline_model.dart';

/// One row of the moments list: [first], and how many adjacent moments of
/// the same kind by the same people it stands for.
class CallMomentRun {
  const CallMomentRun({
    required this.first,
    required this.count,
    required this.lastAt,
  });

  final CallMoment first;
  final int count;

  /// When the last moment in the run happened.
  final int lastAt;
}

bool _foldable(CallMoment moment) =>
    moment.kind == CallMomentKind.joined && moment.userIds.isNotEmpty;

bool _sameRun(CallMoment a, CallMoment b) =>
    _foldable(a) &&
    a.kind == b.kind &&
    a.userIds.length == b.userIds.length &&
    [
      for (var i = 0; i < a.userIds.length; i++) a.userIds[i] == b.userIds[i],
    ].every((same) => same);

/// [moments] (in order) with each run of adjacent joins by the same person
/// folded into one entry. A leave is never in between, because only the
/// last leave of a call is a moment, so these are people dropping and
/// rejoining.
List<CallMomentRun> foldMomentRuns(List<CallMoment> moments) {
  final runs = <CallMomentRun>[];
  for (final moment in moments) {
    if (runs.isNotEmpty && _sameRun(runs.last.first, moment)) {
      final run = runs.removeLast();
      runs.add(
        CallMomentRun(
          first: run.first,
          count: run.count + 1,
          lastAt: moment.at,
        ),
      );
    } else {
      runs.add(CallMomentRun(first: moment, count: 1, lastAt: moment.at));
    }
  }
  return runs;
}
