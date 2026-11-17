// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The beta report: scrolling quickly up through a long channel left the
/// message pane blank until more scrolling brought rows back. The list was
/// fine; one message of 2000 newlines was 44000px of nothing, and on native a
/// lone surrogate threw during layout.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_data/data.dart';

import '../../message_transcript_extent_harness.dart';

/// What the tester had posted into that channel among the history lines: a
/// 2000-line message, a line that holds a lone surrogate, and the same run of
/// blank lines made of braille blanks, which draw nothing either.
final _oddities = {
  120: 'top${'\n' * 2000}bottom',
  121: 'a\uD800b',
  240: List.filled(600, '\u2800').join('\n'),
};

/// A channel shaped like the reported one: a tall recent tail over a long run
/// of one-line history from a single author, so most rows are short continuations.
List<Message> _longHistory(int count, {int tallTail = 30}) => [
  for (var i = 0; i < count; i++)
    Message(
      id: 'h$i',
      channelId: 'c1',
      authorId: i >= count - tallTail ? 'author-${i % 2}' : 'ben',
      authorDisplayName: i >= count - tallTail ? 'Author ${i % 2}' : 'Ben',
      seq: i + 1,
      content: i >= count - tallTail
          ? List.filled(10, 'a long wrapping line of recent chatter').join(' ')
          : _oddities[i] ?? 'history line ${i.toString().padLeft(3, '0')}',
      createdAt: 1700000000000 + i * 1000,
      pending: false,
      failed: false,
    ),
];

Rect _viewport(WidgetTester tester) =>
    tester.getRect(find.byKey(const ValueKey('transcript-under-test')));

/// How many message bodies overlap the viewport right now.
int _visibleRows(WidgetTester tester) {
  final viewport = _viewport(tester);
  final bodies = find.textContaining(
    RegExp('history line|recent chatter|top|bottom|a\uFFFDb'),
    findRichText: true,
  );
  var visible = 0;
  for (final element in bodies.evaluate()) {
    final box = element.renderObject as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) continue;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    if (rect.overlaps(viewport)) visible++;
  }
  return visible;
}

void main() {
  testWidgets('fast wheel scrolling toward older history never blanks the '
      'pane', (tester) async {
    sizeViewport(tester);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      app(
        SizedBox.expand(
          key: const ValueKey('transcript-under-test'),
          child: transcript(
            controller: controller,
            count: 0,
            rows: _longHistory(400),
          ),
        ),
      ),
    );
    await tester.pump();

    final center = _viewport(tester).center;
    final blankFrames = <String>[];
    for (var step = 0; step < 120; step++) {
      final delta = 300.0 + (step * 97) % 500;
      await tester.sendEventToBinding(
        PointerScrollEvent(position: center, scrollDelta: Offset(0, -delta)),
      );
      await tester.pump();
      if (_visibleRows(tester) == 0) {
        final p = controller.position;
        blankFrames.add(
          'step $step: pixels ${p.pixels.toStringAsFixed(0)} of '
          '${p.maxScrollExtent.toStringAsFixed(0)}',
        );
      }
      if (controller.position.pixels >= controller.position.maxScrollExtent) {
        break;
      }
    }

    expect(
      controller.position.pixels,
      controller.position.maxScrollExtent,
      reason: 'the walk must reach the oldest row to have crossed every oddity',
    );
    expect(blankFrames, isEmpty);
  });
}
