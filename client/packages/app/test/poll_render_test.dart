// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Renders [PollView] across the states the redesign exists to fix, so a
/// reviewer sees pixels rather than a description: zero votes, a clear
/// leader, an option you have voted for, a tie (which must mark nobody as
/// leading), and a long question with long option text at phone width.
///
/// **Two rasteriser artifacts to expect and not chase**: a soft [BoxShadow]
/// paints as a hard-edged flat shape, and a hairline stroke can look broken.
/// Neither is a real defect; see `ui_snapshot_support.dart`'s own doc.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/widgets/poll_view.dart';
import 'package:slimm_design_system/design_system.dart';

import 'ui_snapshot_support.dart';

api.Poll _poll({
  required String question,
  required List<String> labels,
  required List<int> votes,
  int? votedOption,
  bool closed = false,
}) => api.Poll(
  question: question,
  options: [
    for (var i = 0; i < labels.length; i++)
      api.PollOption(position: i, label: labels[i], votes: votes[i]),
  ],
  totalVotes: votes.fold(0, (a, b) => a + b),
  votedOption: votedOption,
  closeAt: null,
  closed: closed,
);

final _states = <String, ({api.Poll poll, Size size, String theme})>{
  'poll-zero-votes': (
    poll: _poll(
      question: 'Board game night this Friday?',
      labels: const ['Yes', 'No', "Can't make it"],
      votes: const [0, 0, 0],
    ),
    size: const Size(480, 460),
    theme: 'dark',
  ),
  'poll-clear-leader': (
    poll: _poll(
      question: 'Which map for the next event?',
      labels: const ['Ruins', 'Harbor', 'Foundry'],
      votes: const [2, 11, 3],
    ),
    size: const Size(480, 460),
    theme: 'dark',
  ),
  'poll-voted': (
    poll: _poll(
      question: 'Pizza toppings for Saturday?',
      labels: const ['Pepperoni', 'Mushroom', 'Just cheese'],
      votes: const [5, 2, 1],
      votedOption: 0,
    ),
    size: const Size(480, 460),
    theme: 'light',
  ),
  'poll-tie-marks-no-leader': (
    poll: _poll(
      question: 'Movie night pick?',
      labels: const ['Option A', 'Option B'],
      votes: const [4, 4],
    ),
    size: const Size(480, 400),
    theme: 'dark',
  ),
  'poll-closed-no-votes': (
    poll: _poll(
      question: 'Should we cancel Tuesday?',
      labels: const ['Yes', 'No'],
      votes: const [0, 0],
      closed: true,
    ),
    size: const Size(480, 400),
    theme: 'light',
  ),
  'poll-long-text-phone': (
    poll: _poll(
      question:
          'Given everyone\'s schedules this month, which weekend works '
          'best for the whole group to get together for the game night '
          'we keep putting off?',
      labels: const [
        'The first weekend, right after everyone is back from travel',
        'The last weekend of the month, before the long weekend starts',
      ],
      votes: const [3, 1],
    ),
    size: const Size(390, 760),
    theme: 'light',
  ),
};

void main() {
  setUpAll(loadRealFonts);

  for (final entry in _states.entries) {
    testWidgets('${entry.key} fits its viewport', (tester) async {
      tester.view.physicalSize = entry.value.size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final tokens = entry.value.theme == 'dark'
          ? AppTokens.dark
          : AppTokens.light;
      await tester.pumpWidget(
        RepaintBoundary(
          key: snapshotBoundary,
          child: MaterialApp(
            builder: (_, child) => ProviderScope(child: child!),
            debugShowCheckedModeBanner: false,
            theme: buildTheme(
              entry.value.theme == 'dark' ? Brightness.dark : Brightness.light,
              tokens,
            ),
            home: Scaffold(
              backgroundColor: tokens.surfaceBase,
              body: Padding(
                padding: const EdgeInsets.all(AppSpacing.s16),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: PollView(poll: entry.value.poll, onVote: (_) {}),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      await writeSnapshot(tester, entry.key);

      expect(tester.takeException(), isNull);
    });
  }
}
