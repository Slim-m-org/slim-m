// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A channel flooded with messages: each arrival used to rise in on its own
/// 180ms fade, so at 20 a second four half-faded rows stacked at the bottom,
/// each offset into the one below, and the entrance tickers never stopped.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
  _Channel(this.controller, this.rows);

  final ScrollController controller;
  final ValueNotifier<List<Message>> rows;
  var _next = 0;

  void arrive() => rows.value = [...rows.value, _spam(_next++)];

  String get newestId => 'f${_next - 1}';
}

Future<_Channel> _mount(WidgetTester tester) async {
  h.sizeViewport(tester);
  final controller = ScrollController();
  addTearDown(controller.dispose);
  final rows = ValueNotifier<List<Message>>(h.messages(30));
  addTearDown(rows.dispose);
  await tester.pumpWidget(
    h.app(
      ValueListenableBuilder<List<Message>>(
        valueListenable: rows,
        builder: (_, list, _) =>
            h.transcript(controller: controller, count: 0, rows: list),
      ),
    ),
  );
  await tester.pump();
  return _Channel(controller, rows);
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
      await tester.pump(const Duration(milliseconds: 400));
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
}
