// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Poll cleanup: the voted option used to be told from the others by colour
/// alone, a closed poll said so only in fine caption text nobody reads first,
/// and each option's percentage started at a different horizontal offset
/// depending on how many digits it had.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/widgets/poll_view.dart';
import 'package:slimm_design_system/design_system.dart';

api.Poll _poll({
  int? votedOption,
  bool closed = false,
  List<int> votes = const [1, 3],
}) => api.Poll(
  question: 'Favourite colour?',
  options: [
    for (var i = 0; i < votes.length; i++)
      api.PollOption(position: i, label: 'Option $i', votes: votes[i]),
  ],
  totalVotes: votes.fold(0, (a, b) => a + b),
  votedOption: votedOption,
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
/// clipping, found among the ancestors of its own label text; distinct from
/// the poll card's outer container, which never clips.
Finder _optionRow(String label) => find.ancestor(
  of: find.text(label),
  matching: find.byWidgetPredicate(
    (w) => w is Container && w.clipBehavior == Clip.antiAlias,
  ),
);

/// The track and fill layers inside one option's row: the two plain-coloured
/// [Container]s the row's own bordered one is not (that one carries a
/// [BoxDecoration] instead of a bare `color`).
List<Container> _fillLayers(WidgetTester tester, String label) => tester
    .widgetList<Container>(
      find.descendant(of: _optionRow(label), matching: find.byType(Container)),
    )
    .where((c) => c.color != null)
    .toList();

/// Rec. 709 luma, the same conversion `presence_desaturation_test.dart` uses
/// to check a cue survives greyscale, applied here to the poll's own track
/// and fill tokens rather than to rendered pixels.
double _luma(Color c) => 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;

void main() {
  testWidgets('the voted option carries a check, not colour alone', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_poll(votedOption: 1)));

    expect(find.byIcon(AppIcons.check), findsOneWidget);
  });

  testWidgets('an option nobody has voted for shows no check', (tester) async {
    await tester.pumpWidget(_app(_poll()));

    expect(find.byIcon(AppIcons.check), findsNothing);
  });

  testWidgets('a closed poll carries a glanceable tag beside the question', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_poll(closed: true)));

    expect(find.text('CLOSED'), findsOneWidget);
  });

  testWidgets('an open poll carries no closed tag', (tester) async {
    await tester.pumpWidget(_app(_poll(closed: false)));

    expect(find.text('CLOSED'), findsNothing);
  });

  testWidgets(
    "every option's percentage lines up in a column, whatever its digit "
    'count',
    (tester) async {
      // 1 of 100 votes (1%) beside 99 of 100 (99%): one digit against two.
      await tester.pumpWidget(_app(_poll(votes: const [1, 99])));

      final oneDigit = find.ancestor(
        of: find.text('1%'),
        matching: find.byType(SizedBox),
      );
      final twoDigit = find.ancestor(
        of: find.text('99%'),
        matching: find.byType(SizedBox),
      );
      expect(
        tester.getSize(oneDigit.first).width,
        tester.getSize(twoDigit.first).width,
        reason:
            'a fixed-width percentage column is what keeps every option\'s '
            'bar and label the same shape regardless of the number inside it',
      );
    },
  );

  group('selection is a fill, never the border', () {
    testWidgets(
      "an option's border is the plain separator whether or not it is the "
      'one voted for - an accent border means keyboard focus elsewhere in '
      'this system, and reused here it read backwards',
      (tester) async {
        await tester.pumpWidget(_app(_poll(votedOption: 1)));

        for (final label in ['Option 0', 'Option 1']) {
          final row = tester.widget<Container>(_optionRow(label));
          final border = (row.decoration! as BoxDecoration).border! as Border;
          expect(border.top.color, AppTokens.light.borderSubtle, reason: label);
        }
      },
    );

    testWidgets(
      "an ordinary option's fill is a stronger neutral than its track, not "
      'the near-invisible pair the percentage used to have to carry alone',
      (tester) async {
        await tester.pumpWidget(_app(_poll(votes: const [1, 3])));

        final layers = _fillLayers(tester, 'Option 0');
        expect(layers.length, 2);
        expect(
          layers.map((c) => c.color),
          containsAll(<Color>[
            AppTokens.light.borderSubtle,
            AppTokens.light.borderStrong,
          ]),
        );
      },
    );

    /// This used to assert `accentSoft`, and that was wrong against the
    /// track it sits on: the track is `borderSubtle`, and `accentSoft` is
    /// darker than it in both themes (light #DAE9F2 on #DCE0E5, dark
    /// #1D2B33 on #2E333A). The option you voted for rendered as a recess
    /// while the one you did not rendered as a bar, which the owner
    /// reported on a 50/50 poll: two identical shares, two different
    /// colours, and their own vote the less visible of the two.
    testWidgets(
      'the voted option gets the same fill as any other, because the bar '
      'is the share and the check is the vote',
      (tester) async {
        await tester.pumpWidget(_app(_poll(votedOption: 1)));

        final voted = _fillLayers(tester, 'Option 1').map((c) => c.color);
        final ordinary = _fillLayers(tester, 'Option 0').map((c) => c.color);

        expect(
          voted,
          containsAll(<Color>[
            AppTokens.light.borderSubtle,
            AppTokens.light.borderStrong,
          ]),
        );
        expect(
          voted.toSet(),
          ordinary.toSet(),
          reason: 'two equal shares must never draw two different colours',
        );
      },
    );

    testWidgets(
      'an option with no votes at all still shows a track, rather than '
      'blending into the card the way a fully transparent fill used to',
      (tester) async {
        await tester.pumpWidget(_app(_poll(votes: const [0, 0])));

        final layers = _fillLayers(tester, 'Option 0');
        expect(
          layers.map((c) => c.color),
          contains(AppTokens.light.borderSubtle),
        );
      },
    );

    test('the track and an ordinary fill differ enough in greyscale luma to '
        'read by contrast alone, in every theme', () {
      for (final tokens in [
        AppTokens.light,
        AppTokens.dark,
        AppTokens.trueBlack,
      ]) {
        final delta = (_luma(tokens.borderStrong) - _luma(tokens.borderSubtle))
            .abs();
        expect(
          delta,
          greaterThan(0.03),
          reason:
              'below this a fill reads the same as its track to anyone who '
              'cannot use the hue difference, which is exactly the '
              'complaint the percentage-only bars drew',
        );
      }
    });
  });

  group('an option row is reachable and votable from the keyboard', () {
    setUp(() {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
    });
    tearDown(() {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic;
    });

    testWidgets('Tab lands on the first option and draws a focus ring', (
      tester,
    ) async {
      await tester.pumpWidget(_app(_poll()));

      final row = tester.widget<Container>(_optionRow('Option 0'));
      expect(
        ((row.decoration! as BoxDecoration).border! as Border).top.color,
        AppTokens.light.borderSubtle,
        reason: 'nothing has been tabbed to yet',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();

      final focused = tester.widget<Container>(_optionRow('Option 0'));
      expect(
        ((focused.decoration! as BoxDecoration).border! as Border).top.color,
        AppTokens.light.focusRing,
        reason:
            'a row a keyboard cannot land on has no route to voting, and '
            'one that takes focus silently is a route nobody can see',
      );
    });

    testWidgets('Enter casts a vote for the focused option', (tester) async {
      final voted = await _tabAndPress(
        tester,
        LogicalKeyboardKey.enter,
        poll: _poll(),
      );
      expect(voted, 0, reason: 'Enter was reachable but never runnable');
    });

    testWidgets('Space also casts a vote', (tester) async {
      final voted = await _tabAndPress(
        tester,
        LogicalKeyboardKey.space,
        poll: _poll(),
      );
      expect(voted, 0);
    });

    testWidgets('a closed poll never takes keyboard focus at all', (
      tester,
    ) async {
      final voted = await _tabAndPress(
        tester,
        LogicalKeyboardKey.enter,
        poll: _poll(closed: true),
      );
      expect(
        voted,
        isNull,
        reason:
            'a closed poll refuses the vote server-side regardless; a '
            'focusable, activatable row here would just be a false promise',
      );
    });
  });
}

/// Tabs to the first option and presses [key], returning whatever option
/// [PollView.onVote] was called with, if any.
Future<int?> _tabAndPress(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  required api.Poll poll,
}) async {
  int? voted;
  await tester.pumpWidget(
    MaterialApp(
      builder: (_, child) => ProviderScope(child: child!),
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(
        body: PollView(poll: poll, onVote: (i) => voted = i),
      ),
    ),
  );
  await tester.sendKeyEvent(LogicalKeyboardKey.tab);
  await tester.pumpAndSettle();
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
  return voted;
}
