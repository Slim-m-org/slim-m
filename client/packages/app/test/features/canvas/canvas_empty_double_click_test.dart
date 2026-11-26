// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A double click on empty board with a mouse opens a text box there; a single click, a click on a card, or a finger does not.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/async_wait.dart';
import 'canvas_pane_harness.dart';
import 'canvas_text_pane_support.dart';

Future<void> _mouseClick(WidgetTester tester, Offset world) async {
  final gesture = await tester.startGesture(
    screenFor(tester, world),
    kind: PointerDeviceKind.mouse,
  );
  await gesture.up();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('two quick mouse clicks on empty board open a text editor', (
    tester,
  ) async {
    final fixture = await openPane(tester);
    await tester.tap(find.bySemanticsLabel('Pan'));
    await tester.pump();

    await _mouseClick(tester, const Offset(300, 200));
    expect(editor, findsNothing);
    await _mouseClick(tester, const Offset(302, 201));
    await pumpFrames(tester);

    expect(editor, findsOneWidget);
    expect(fixture.posted, isEmpty);
  });

  testWidgets('a single click, or two far apart, open nothing', (tester) async {
    await openPane(tester);
    await tester.tap(find.bySemanticsLabel('Pan'));
    await tester.pump();

    await _mouseClick(tester, const Offset(300, 200));
    await _mouseClick(tester, const Offset(500, 400));
    await pumpFrames(tester);

    expect(editor, findsNothing);
  });

  testWidgets('a double click on a card opens no new text box', (tester) async {
    await openPane(tester, objects: [canvasNoteJson('n', x: 300)]);
    await tester.tap(find.bySemanticsLabel('Pan'));
    await tester.pump();

    await _mouseClick(tester, const Offset(310, 20));
    await _mouseClick(tester, const Offset(310, 20));
    await pumpFrames(tester);

    expect(editor, findsNothing);
  });

  testWidgets('two finger taps on empty board open nothing', (tester) async {
    await openPane(tester);
    await tester.tap(find.bySemanticsLabel('Pan'));
    await tester.pump();

    await fingerTapTwice(tester, const Offset(300, 200));

    expect(editor, findsNothing);
  });
}
