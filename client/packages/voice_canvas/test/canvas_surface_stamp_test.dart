// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The board's Stamp tool (decision 0121): a tap places at the press with no
/// side, so the app's default applies; a drag sizes the stamp around the
/// press, its longest side twice the drag, previewed while it moves and
/// placed only once the pointer lifts.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

void main() {
  late List<(Offset, double?)> placed;
  late List<(Offset, double?)> dragged;

  Future<CanvasDocument> pump(WidgetTester tester) async {
    placed = [];
    dragged = [];
    final document = CanvasDocument();
    addTearDown(document.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasSurface(
          document: document,
          ink: const Color(0xFFE86A5C),
          tool: CanvasTool.stamp,
          onStroke: (_) {},
          onStampPlace: (world, side) => placed.add((world, side)),
          onStampDrag: (world, side) => dragged.add((world, side)),
        ),
      ),
    );
    await tester.pump();
    return document;
  }

  testWidgets('a tap places at the press with the default size', (
    tester,
  ) async {
    await pump(tester);
    await tester.tapAt(const Offset(200, 150));
    await tester.pump();
    expect(placed, [(const Offset(200, 150), null)]);
    expect(dragged, isEmpty);
  });

  testWidgets('a drag sizes around the press and places on release', (
    tester,
  ) async {
    await pump(tester);
    final gesture = await tester.startGesture(const Offset(200, 150));
    await gesture.moveTo(const Offset(230, 150));
    await tester.pump();
    await gesture.moveTo(const Offset(240, 180));
    await tester.pump();
    expect(placed, isEmpty, reason: 'nothing is placed mid-drag');
    expect(dragged.last, (const Offset(200, 150), 100.0));

    await gesture.up();
    await tester.pump();
    expect(placed, [(const Offset(200, 150), 100.0)]);
    expect(dragged.last.$2, isNull, reason: 'the preview ends');
  });

  testWidgets('a wobble inside a tap stays a tap', (tester) async {
    await pump(tester);
    final gesture = await tester.startGesture(const Offset(200, 150));
    await gesture.moveTo(const Offset(203, 152));
    await gesture.up();
    await tester.pump();
    expect(placed, [(const Offset(200, 150), null)]);
  });

  test('the stamp tool places a new item, like the pen', () {
    expect(CanvasTool.stamp.placesInk, isTrue);
  });
}
