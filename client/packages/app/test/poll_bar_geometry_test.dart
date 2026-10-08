// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A poll option's fill bar is anchored to the track's left edge and is as
/// wide as the option's share of the track.
///
/// Reported 2026-10-02 ("polls dont look right for split values"): the bar
/// of a 50% option was drawn centred. The stack centres every child that is
/// not positioned, and a fractional box narrower than the track floats in
/// the middle of it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/widgets/poll_view.dart';
import 'package:slimm_design_system/design_system.dart';

api.Poll _poll(List<int> votes, {int? voted, int? total}) => api.Poll(
  question: 'q',
  options: [
    for (var i = 0; i < votes.length; i++)
      api.PollOption(position: i, label: 'opt$i', votes: votes[i]),
  ],
  totalVotes: total ?? votes.fold(0, (a, b) => a + b),
  votedOption: voted,
  closeAt: null,
  closed: false,
);

Future<void> _pump(
  WidgetTester tester,
  api.Poll poll,
  double width,
  Brightness b,
) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      builder: (_, child) => ProviderScope(child: child!),
      theme: buildTheme(
        b,
        b == Brightness.dark ? AppTokens.dark : AppTokens.light,
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width.clamp(0, 420),
            child: PollView(poll: poll, onVote: (_) {}),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  const cases = <String, List<int>>{
    'split 0/1/1/0 (2 votes)': [0, 1, 1, 0],
    'quarter 1/3': [1, 3],
    'thirds 1/1/1': [1, 1, 1],
    'full 4/0': [4, 0],
  };
  for (final width in [390.0, 1280.0]) {
    for (final b in Brightness.values) {
      cases.forEach((name, votes) {
        testWidgets(
          '$name bars are left-anchored and share-wide at $width ${b.name}',
          (tester) async {
            await _pump(tester, _poll(votes, voted: 1), width, b);
            final total = votes.fold<int>(0, (a, c) => a + c);
            for (var i = 0; i < votes.length; i++) {
              final row = find.ancestor(
                of: find.text('opt$i'),
                matching: find.byWidgetPredicate(
                  (w) => w is Container && w.clipBehavior == Clip.antiAlias,
                ),
              );
              final trackRect = tester.getRect(row.first);
              final bar = find.descendant(
                of: row.first,
                matching: find.byType(FractionallySizedBox),
              );
              final barRect = tester.getRect(bar);
              final fill = trackRect.deflate(1);
              final expected = fill.width * votes[i] / total;
              expect(barRect.left, closeTo(fill.left, 1), reason: 'opt$i left');
              expect(
                barRect.width,
                closeTo(expected, 1),
                reason: 'opt$i width',
              );
            }
          },
        );
      });
    }
  }
}
