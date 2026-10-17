// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The reported bug: the transcript's scrollbar "jumps around a lot and
/// doesn't move cleanly".
///
/// The cause is not pagination, which was the reported guess and is worth
/// disproving here rather than only in prose: every scrolling test below runs
/// against a transcript already at its true start, so nothing pages in during
/// any of them and the jitter is entirely reproducible without it. It comes
/// from `ListView`'s own extent estimate being an average over just the rows
/// laid out at that instant; see `message_transcript_extent.dart`'s library
/// doc for the mechanism and the measured before-and-after, and
/// `message_transcript_extent_harness.dart` for why the fixture is shaped the
/// way it is.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row.dart';
import 'package:slimm_app/src/features/messages/widgets/message_transcript_extent.dart';

import 'message_transcript_extent_harness.dart';

void main() {
  group('the estimator on its own', () {
    test('answers exactly once the last row is built', () {
      final estimator = TranscriptExtentEstimator();

      expect(
        estimator.estimate(
          childCount: 50,
          lastIndex: 49,
          trailingScrollOffset: 5000,
        ),
        5000,
        reason:
            'nothing is left to extrapolate over, so the measured total is '
            'the answer and no settled average may perturb it',
      );
    });

    test('one unusually tall row barely moves the answer', () {
      final steady = TranscriptExtentEstimator();
      // Twenty layouts of a list running at a level 100px per row.
      for (var lastIndex = 30; lastIndex < 50; lastIndex++) {
        steady.estimate(
          childCount: 300,
          lastIndex: lastIndex,
          trailingScrollOffset: (lastIndex + 1) * 100,
        );
      }
      final before = steady.estimate(
        childCount: 300,
        lastIndex: 50,
        trailingScrollOffset: 5100,
      )!;

      // The next row is four times the height of any before it.
      final after = steady.estimate(
        childCount: 300,
        lastIndex: 51,
        trailingScrollOffset: 5500,
      )!;

      expect(
        (after - before).abs() / before,
        lessThan(0.02),
        reason:
            'the average is multiplied by every row not yet built, so letting '
            'one outlier move it is what made the raw per-frame average '
            'unusable; undamped, this single row shifts the answer by 7%',
      );
    });

    test(
      'reset forgets what settled rather than carrying it to the next channel',
      () {
        final carried = TranscriptExtentEstimator();
        // Settle firmly on 100px rows, the shape of a long-winded channel.
        for (var lastIndex = 30; lastIndex < 80; lastIndex++) {
          carried.estimate(
            childCount: 300,
            lastIndex: lastIndex,
            trailingScrollOffset: (lastIndex + 1) * 100,
          );
        }
        final beforeReset = carried.estimate(
          childCount: 300,
          lastIndex: 20,
          trailingScrollOffset: 400,
        )!;

        carried.reset();
        final afterReset = carried.estimate(
          childCount: 300,
          lastIndex: 20,
          trailingScrollOffset: 400,
        )!;

        expect(
          afterReset,
          lessThan(beforeReset / 2),
          reason:
              'the next channel is built of 19px rows, and an average settled '
              'on the last one would keep claiming it is five times as long '
              'as it is until enough new layouts had washed it out',
        );
      },
    );
  });

  group('the scrollbar while reading back through history', () {
    testWidgets('the fixture really does have sharply varying row heights', (
      tester,
    ) async {
      sizeViewport(tester);
      final controller = ScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        app(transcript(controller: controller, count: 300)),
      );
      await tester.pump();

      final heights = tester
          .widgetList<MessageRow>(find.byType(MessageRow))
          .map((row) => tester.getSize(find.byWidget(row)).height)
          .toList();
      final shortest = heights.reduce((a, b) => a < b ? a : b);
      final tallest = heights.reduce((a, b) => a > b ? a : b);

      expect(
        tallest,
        greaterThan(shortest * 3),
        reason:
            'a list of near-uniform rows has a stable average and no jitter '
            'to find, so a fixture without this spread would pass against '
            'the bug it is meant to catch',
      );
    });

    testWidgets('the thumb tracks the scroll instead of sliding backwards', (
      tester,
    ) async {
      sizeViewport(tester);
      final controller = ScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        app(transcript(controller: controller, count: 300)),
      );
      await tester.pump();
      final travel = await scrollThrough(tester, controller);

      expect(
        travel.steps,
        greaterThan(300),
        reason: 'enough of a run to judge',
      );
      // Measured: 28 of 401 frames with the fix, 175 without it.
      expect(
        travel.backwardsSteps,
        lessThan(60),
        reason:
            'the reader is scrolling one way the whole time, so the thumb '
            'going the other way is the reported bug happening',
      );
      // Measured: 0.36% with the fix, 2.83% without it.
      expect(
        travel.worstBackwards,
        lessThan(0.01),
        reason: 'and no single lurch big enough to see on the track',
      );
    });

    testWidgets('turning round and reading back down does not move it either', (
      tester,
    ) async {
      sizeViewport(tester);
      final controller = ScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        app(transcript(controller: controller, count: 300)),
      );
      await tester.pump();
      for (var i = 0; i < 120; i++) {
        controller.jumpTo(controller.position.pixels + step);
        await tester.pump();
      }
      final atDeepest = controller.position.maxScrollExtent;

      var worstDrift = 0.0;
      while (controller.position.pixels > step) {
        controller.jumpTo(controller.position.pixels - step);
        await tester.pump();
        final drift =
            (controller.position.maxScrollExtent - atDeepest).abs() / atDeepest;
        if (drift > worstDrift) worstDrift = drift;
      }

      // Measured: 2.8% with the fix, 19.1% without it.
      expect(
        worstDrift,
        lessThan(0.05),
        reason:
            'nothing about the conversation changes by scrolling back toward '
            'the newest message, so the total the scrollbar is drawn from '
            'should barely move either - a reader who scrolls up and back '
            'down should find the thumb roughly where they left it, rather '
            'than a fifth of the track away',
      );
    });

    testWidgets('the thumb keeps its size instead of breathing', (
      tester,
    ) async {
      sizeViewport(tester);
      final controller = ScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        app(transcript(controller: controller, count: 300)),
      );
      await tester.pump();
      final travel = await scrollThrough(tester, controller);

      // Measured: 5.3% with the fix, 21.3% without it.
      expect(
        travel.swing,
        lessThan(0.08),
        reason:
            'the extent is the thumb size as well as its position, so an '
            'extent that breathes is a thumb that visibly grows and shrinks '
            'while nothing about the conversation has changed',
      );
    });
  });

  testWidgets('switching channels does not carry the old one\'s measurements', (
    tester,
  ) async {
    sizeViewport(tester);
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      app(transcript(controller: controller, count: 300)),
    );
    await tester.pump();
    for (var i = 0; i < 120; i++) {
      controller.jumpTo(controller.position.pixels + step);
      await tester.pump();
    }

    // The same widget in the same slot, so the State - and the estimator on it - survives, exactly as a real channel switch does.
    await tester.pumpWidget(
      app(
        transcript(
          controller: controller,
          count: 300,
          channelId: 'c2',
          short: true,
        ),
      ),
    );
    // `TranscriptScrollTracker.resetForChannelSwitch` does the jump for real; the short read after it is what makes this a claim about prompt recovery rather than an instant one, since the first layout after a swap still reports the old channel's offsets.
    controller.jumpTo(0);
    await tester.pump();
    await readAWhile(tester, controller);
    final switched = controller.position.maxScrollExtent;

    // A different key forces a brand new State, and so a brand new estimator: without it this control would reuse the very estimator under test and could never disagree with it.
    final fresh = ScrollController();
    addTearDown(fresh.dispose);
    await tester.pumpWidget(
      app(
        transcript(
          key: const ValueKey('cold'),
          controller: fresh,
          count: 300,
          channelId: 'c2',
          short: true,
        ),
      ),
    );
    await tester.pump();
    await readAWhile(tester, fresh);

    expect(
      switched,
      closeTo(
        fresh.position.maxScrollExtent,
        fresh.position.maxScrollExtent * 0.1,
      ),
      reason:
          'a channel reached by switching must be measured like one opened '
          'cold: the old channel had far taller rows, so an average settled '
          'against it would claim this conversation is much longer than it '
          'is and shrink the thumb to nothing',
    );
  });

  testWidgets(
    'a page of older history still steps the extent, which this fix does not '
    'claim to remove',
    (tester) async {
      sizeViewport(tester);
      final controller = ScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        app(transcript(controller: controller, count: 100)),
      );
      await tester.pump();
      controller.jumpTo(controller.position.maxScrollExtent / 2);
      await tester.pump();
      final before = controller.position.maxScrollExtent;

      await tester.pumpWidget(
        app(transcript(controller: controller, count: 150)),
      );
      await tester.pump();

      expect(
        controller.position.maxScrollExtent,
        greaterThan(before),
        reason:
            'the extent is the loaded window, so paging in older history '
            'genuinely lengthens it - one discrete step where the reader '
            'already is, not the per-frame sawtooth the other tests here '
            'pin down. Making the scrollbar a proportion of the whole '
            'conversation instead would need a total the client cannot ask '
            'for; see channel_history.dart.',
      );
    },
  );
}
