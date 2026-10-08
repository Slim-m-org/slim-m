// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rest of the poll redesign, split out of `poll_view_test.dart` to stay
/// under this repo's line budget: the leading-option cue, the zero-vote
/// state's own copy, and the option row's touch target at phone width.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/widgets/poll_view.dart';
import 'package:slimm_design_system/design_system.dart';

api.Poll _poll({bool closed = false, List<int> votes = const [1, 3]}) =>
    api.Poll(
      question: 'Favourite colour?',
      options: [
        for (var i = 0; i < votes.length; i++)
          api.PollOption(position: i, label: 'Option $i', votes: votes[i]),
      ],
      totalVotes: votes.fold(0, (a, b) => a + b),
      votedOption: null,
      closeAt: null,
      closed: closed,
    );

Widget _app(api.Poll poll) => MaterialApp(
  builder: (_, child) => ProviderScope(child: child!),
  theme: buildTheme(Brightness.light, AppTokens.light),
  home: Scaffold(
    body: PollView(poll: poll, onVote: (_) {}),
  ),
);

/// The one [Container] per option row that carries its own border and
/// clipping; see `poll_view_test.dart`'s own copy of this finder for why.
Finder _optionRow(String label) => find.ancestor(
  of: find.text(label),
  matching: find.byWidgetPredicate(
    (w) => w is Container && w.clipBehavior == Clip.antiAlias,
  ),
);

/// The track and fill layers inside one option's row; see
/// `poll_view_test.dart`'s own copy of this finder for why.
List<Container> _fillLayers(WidgetTester tester, String label) => tester
    .widgetList<Container>(
      find.descendant(of: _optionRow(label), matching: find.byType(Container)),
    )
    .where((c) => c.color != null)
    .toList();

void main() {
  group('the option strictly ahead of every other', () {
    testWidgets('carries the leading icon and a semibold label', (
      tester,
    ) async {
      await tester.pumpWidget(_app(_poll(votes: const [1, 3])));

      expect(find.byIcon(AppIcons.pollLeading), findsOneWidget);
      final label = tester.widget<Text>(find.text('Option 1'));
      expect((label.textSpan! as TextSpan).style!.fontWeight, AppWeights.semi);
    });

    /// The leading option used to take `textSecondary` as its fill so it
    /// read heavier than an ordinary bar. Two things were wrong with it.
    /// The label sits on top of the bar, and at dark #A7AEB6 under
    /// `textPrimary` #ECEDEF that is about 1.8:1 - the heavier bar cost the
    /// label its legibility. And there is no neutral both stronger than
    /// `borderStrong` and still legible under the label, so the weight had
    /// nowhere to go. The glyph and the semibold label already carry
    /// "leading" without colour, which is what this asserts instead.
    testWidgets('is carried by its glyph and weight, not by a heavier bar', (
      tester,
    ) async {
      await tester.pumpWidget(_app(_poll(votes: const [1, 3])));

      final leading = _fillLayers(tester, 'Option 1').map((c) => c.color);
      final ordinary = _fillLayers(tester, 'Option 0').map((c) => c.color);

      expect(leading.toSet(), ordinary.toSet());
      expect(find.byIcon(AppIcons.pollLeading), findsOneWidget);
    });

    testWidgets('is never marked on a tie for first place', (tester) async {
      await tester.pumpWidget(_app(_poll(votes: const [2, 2])));

      expect(find.byIcon(AppIcons.pollLeading), findsNothing);
    });

    testWidgets('is never marked when nobody has voted', (tester) async {
      await tester.pumpWidget(_app(_poll(votes: const [0, 0])));

      expect(find.byIcon(AppIcons.pollLeading), findsNothing);
    });

    testWidgets('says so in its own semantics label', (tester) async {
      await tester.pumpWidget(_app(_poll(votes: const [1, 3])));

      expect(
        find.bySemanticsLabel(RegExp(r'Option 1,.*leading$')),
        findsOneWidget,
      );
    });
  });

  group('a poll with no votes yet', () {
    testWidgets(
      'says so in words instead of drawing an identical 0% on every option',
      (tester) async {
        await tester.pumpWidget(_app(_poll(votes: const [0, 0])));

        expect(
          find.text('No votes yet. Tap an option to vote.'),
          findsOneWidget,
        );
        expect(find.textContaining('%'), findsNothing);
      },
    );

    testWidgets('reads as past tense once closed with nobody having voted', (
      tester,
    ) async {
      await tester.pumpWidget(_app(_poll(votes: const [0, 0], closed: true)));

      expect(find.text('No one voted.'), findsOneWidget);
    });

    testWidgets('still shows a real count the moment it has one', (
      tester,
    ) async {
      await tester.pumpWidget(_app(_poll(votes: const [1, 0])));

      expect(find.text('1 vote'), findsOneWidget);
    });
  });

  group('the card hugs its own content', () {
    testWidgets(
      'and does not stretch to fill a bounded-but-loose parent height',
      (tester) async {
        // Align's own bounded height is what a scrollable list's unbounded one had hidden.
        await tester.pumpWidget(
          MaterialApp(
            builder: (_, child) => ProviderScope(child: child!),
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: Scaffold(
              body: SizedBox(
                height: 800,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: PollView(poll: _poll(), onVote: (_) {}),
                ),
              ),
            ),
          ),
        );

        final size = tester.getSize(find.byType(PollView));
        expect(
          size.height,
          lessThan(300),
          reason:
              'a three-option card has no business anywhere near the 800px '
              'the parent offered; it must size to its own content',
        );
      },
    );
  });

  group('touch targets', () {
    testWidgets('an option row meets the 44pt floor at phone width', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_app(_poll()));

      final row = tester.widget<Container>(_optionRow('Option 0'));
      expect(row.constraints!.maxHeight, AppSizes.rowTouch);
    });

    testWidgets('stays at the compact control height on a wide window', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_app(_poll()));

      final row = tester.widget<Container>(_optionRow('Option 0'));
      expect(row.constraints!.maxHeight, AppSizes.controlMd);
    });
  });
}
