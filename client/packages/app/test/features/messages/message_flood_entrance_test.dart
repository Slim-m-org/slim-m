// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A channel flooded with messages: each arrival used to rise in on its own
/// 180ms fade, so at 20 a second four half-faded rows stacked at the bottom,
/// each offset into the one below, and the entrance tickers never stopped.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/screens/channel_transcript_scroll.dart';
import 'package:slimm_app/src/features/messages/widgets/message_entrance.dart';
import 'package:slimm_app/src/features/messages/widgets/message_transcript_widgets.dart';
import 'package:slimm_data/data.dart';

import '../../message_transcript_extent_harness.dart' as h;

const _frame = Duration(milliseconds: 16);

/// Twenty a second, the rate a bot or a busy channel can reach.
const _floodGap = Duration(milliseconds: 50);

Message _spam(int i) => Message(
  id: 'f$i',
  channelId: 'c1',
  authorId: 'author-${i % 3}',
  authorDisplayName: 'Spammer ${i % 3}',
  seq: 1000 + i,
  content: 'spam message number $i',
  createdAt: 1700100000000 + i * 50,
  pending: false,
  failed: false,
);

/// Rows painted part way through their entrance, the ones a reader sees as half there.
final _midEntrance = find.descendant(
  of: find.byWidgetPredicate((w) => w is MessageEntrance),
  matching: find.byWidgetPredicate((w) => w is Opacity && w.opacity < 1),
);

class _Channel {
  _Channel(this.tracker, this.rows, this.pinnedAway);

  final TranscriptScrollTracker tracker;
  final ValueNotifier<List<Message>> rows;

  /// Overrides the tracker's answer, as a reader the pane counts as away would.
  final ValueNotifier<bool> pinnedAway;
  var _next = 0;

  ScrollController get controller => tracker.controller;

  void arrive() => rows.value = [...rows.value, _spam(_next++)];

  /// Whether the row that just landed is the one rising in.
  bool get newestRises => find
      .descendant(of: find.byKey(ValueKey(newestId)), matching: _midEntrance)
      .evaluate()
      .isNotEmpty;

  String get newestId => 'f${_next - 1}';
}

Future<_Channel> _mount(WidgetTester tester) async {
  h.sizeViewport(tester);
  final tracker = TranscriptScrollTracker(markRead: (_, _, _) {});
  addTearDown(tracker.dispose);
  final rows = ValueNotifier<List<Message>>(h.messages(30));
  addTearDown(rows.dispose);
  final pinnedAway = ValueNotifier(false);
  addTearDown(pinnedAway.dispose);
  await tester.pumpWidget(
    h.app(
      ListenableBuilder(
        listenable: Listenable.merge([rows, pinnedAway]),
        builder: (_, _) => h.transcript(
          controller: tracker.controller,
          count: 0,
          rows: rows.value,
          atLatest: !pinnedAway.value && tracker.atLatest,
        ),
      ),
    ),
  );
  await tester.pump();
  return _Channel(tracker, rows, pinnedAway);
}

/// The newest row's painted bottom edge, entrance offset included.
double _newestBottom(WidgetTester tester, _Channel channel) => tester
    .getBottomLeft(
      find
          .descendant(
            of: find.byKey(ValueKey(channel.newestId)),
            matching: find.byWidgetPredicate((w) => w is MessageRowExtras),
          )
          .first,
    )
    .dy;

void main() {
  testWidgets('a flood lands still after its first message, pinned to the '
      'bottom', (tester) async {
    final channel = await _mount(tester);
    var mostMidEntrance = 0;
    var framesMidEntrance = 0;
    final bottoms = <double>{};
    for (var i = 0; i < 60; i++) {
      channel.arrive();
      for (
        var f = 0;
        f < _floodGap.inMilliseconds ~/ _frame.inMilliseconds;
        f++
      ) {
        await tester.pump(_frame);
        final mid = _midEntrance.evaluate().length;
        if (mid > mostMidEntrance) mostMidEntrance = mid;
        if (mid > 0) framesMidEntrance++;
        expect(channel.controller.position.pixels, 0);
        if (i > 0) bottoms.add(_newestBottom(tester, channel));
      }
    }

    expect(mostMidEntrance, 1, reason: 'only the first of a burst rises in');
    expect(
      framesMidEntrance,
      lessThanOrEqualTo(3),
      reason: 'the first entrance ends when the second message lands',
    );
    expect(
      bottoms,
      hasLength(1),
      reason: 'every later row lands in place, frame after frame',
    );
  });

  testWidgets('a message arriving on its own still rises in', (tester) async {
    final channel = await _mount(tester);
    for (var round = 0; round < 2; round++) {
      channel.arrive();
      await tester.pump(_frame);
      expect(_midEntrance, findsOneWidget);
      await tester.pump(EntranceGate.quietGap);
      expect(_midEntrance, findsNothing);
    }
  });

  testWidgets('a message that arrived while the reader was in history does '
      'not rise in when they come back to it', (tester) async {
    final channel = await _mount(tester);
    channel.controller.jumpTo(600);
    await tester.pump();
    channel.arrive();
    await tester.pump(_frame);
    channel.controller.jumpTo(0);
    await tester.pump(_frame);
    expect(find.byKey(ValueKey(channel.newestId)), findsOneWidget);
    expect(_midEntrance, findsNothing);
  });

  testWidgets('a steady 4-5 a second, gaps jittering around the entrance, '
      'lands still after its first message until the channel goes quiet', (
    tester,
  ) async {
    final channel = await _mount(tester);
    const gaps = [220, 250, 150, 200, 240, 170, 230, 190, 210, 160, 250, 200];
    var risen = 0;
    for (final gap in gaps) {
      channel.arrive();
      await tester.pump(_frame);
      if (channel.newestRises) risen++;
      await tester.pump(Duration(milliseconds: gap) - _frame);
    }
    expect(risen, 1, reason: 'only the first of a steady stream rises in');

    await tester.pump(const Duration(seconds: 1));
    channel.arrive();
    await tester.pump(_frame);
    expect(channel.newestRises, isTrue, reason: 'a lone message after quiet');
  });

  testWidgets('purging a flood leaves the message before it in place', (
    tester,
  ) async {
    final channel = await _mount(tester);
    final beforeFlood = channel.rows.value;
    for (var i = 0; i < 80; i++) {
      channel.arrive();
      await tester.pump(_floodGap);
    }
    await tester.pump(const Duration(seconds: 2));
    channel.rows.value = beforeFlood;
    await tester.pump(_frame);
    expect(find.byKey(ValueKey(beforeFlood.last.id)), findsOneWidget);
    expect(_midEntrance, findsNothing);
  });

  testWidgets('the entrance follows the at-latest answer it is handed, not '
      'its own reading of the scroll', (tester) async {
    final channel = await _mount(tester);
    channel.pinnedAway.value = true;
    channel.arrive();
    await tester.pump(_frame);
    expect(channel.controller.position.pixels, 0);
    expect(_midEntrance, findsNothing);
  });

  testWidgets('reduce motion lands a lone message at once', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final channel = await _mount(tester);
    channel.arrive();
    await tester.pump(_frame);
    expect(find.byKey(ValueKey(channel.newestId)), findsOneWidget);
    expect(_midEntrance, findsNothing);
  });

  testWidgets('switching channels re-seeds the gate: a low-seq channel '
      'still animates its arrivals and its open row stays still', (
    tester,
  ) async {
    h.sizeViewport(tester);
    final tracker = TranscriptScrollTracker(markRead: (_, _, _) {});
    addTearDown(tracker.dispose);
    Message row(String channel, int seq) => Message(
      id: '$channel-$seq',
      channelId: channel,
      authorId: 'author-$seq',
      authorDisplayName: 'Author $seq',
      seq: seq,
      content: 'message $seq in $channel',
      createdAt: 1700100000000 + seq * 50,
      pending: false,
      failed: false,
    );
    final view = ValueNotifier<(String, List<Message>)>((
      'busy',
      [for (var s = 4990; s <= 5000; s++) row('busy', s)],
    ));
    addTearDown(view.dispose);
    await tester.pumpWidget(
      h.app(
        ValueListenableBuilder(
          valueListenable: view,
          builder: (_, v, _) => h.transcript(
            controller: tracker.controller,
            count: 0,
            channelId: v.$1,
            rows: v.$2,
          ),
        ),
      ),
    );
    await tester.pump();

    view.value = ('quiet', [for (var s = 110; s <= 120; s++) row('quiet', s)]);
    await tester.pump(_frame);
    expect(
      _midEntrance,
      findsNothing,
      reason: 'opening a channel replays nothing',
    );

    await tester.pump(EntranceGate.quietGap);
    view.value = ('quiet', [...view.value.$2, row('quiet', 121)]);
    await tester.pump(_frame);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('quiet-121')),
        matching: _midEntrance,
      ),
      findsOneWidget,
    );
  });
}
