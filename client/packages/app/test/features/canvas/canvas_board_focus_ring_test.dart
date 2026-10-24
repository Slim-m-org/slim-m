// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The board's focus ring belongs to keyboard use only: a shortcut's held
/// modifiers or a click must not leave the whole canvas outlined.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_board_keys.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

Future<void> _pump(WidgetTester tester) => tester.pumpWidget(
  MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: Scaffold(
      body: Column(
        children: [
          const TextField(),
          Expanded(
            child: CanvasBoardKeys(
              document: CanvasDocument()..setViewport(const Size(800, 600)),
              tool: CanvasTool.pan,
              onOpenActions: (_) {},
              onPlaceNote: (_) {},
              onPlaceShape: (_) {},
              child: const SizedBox.expand(),
            ),
          ),
        ],
      ),
    ),
  ),
);

bool _ringShown(WidgetTester tester) => tester
    .widgetList<DecoratedBox>(
      find.descendant(
        of: find.byType(CanvasBoardKeys),
        matching: find.byType(DecoratedBox),
      ),
    )
    .any((box) => (box.decoration as BoxDecoration?)?.border != null);

void main() {
  testWidgets('a key the board handles shows the ring, and a click hides it', (
    tester,
  ) async {
    await _pump(tester);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(_ringShown(tester), isTrue);

    await tester.tap(find.byType(CanvasBoardKeys), warnIfMissed: false);
    await tester.pump();
    expect(_ringShown(tester), isFalse);
  });

  testWidgets('focus arriving under a held shortcut modifier draws no ring', (
    tester,
  ) async {
    await _pump(tester);
    await tester.pump();
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    tester
        .widget<Focus>(
          find
              .descendant(
                of: find.byType(CanvasBoardKeys),
                matching: find.byType(Focus),
              )
              .first,
        )
        .focusNode!
        .requestFocus();
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(_ringShown(tester), isFalse);
  });

  testWidgets('holding Enter does not repeat placement on KeyRepeatEvent', (
    tester,
  ) async {
    var placed = 0;
    final focusNode = FocusNode();
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: CanvasBoardKeys(
            document: CanvasDocument()..setViewport(const Size(800, 600)),
            tool: CanvasTool.note,
            focusNode: focusNode,
            onOpenActions: (_) {},
            onPlaceNote: (_) => placed++,
            onPlaceShape: (_) {},
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(placed, 1);
  });

  testWidgets(
    'discrete keys ([ ] 0 Escape) act once on KeyDownEvent and ignore KeyRepeatEvent',
    (tester) async {
      final document = CanvasDocument()
        ..setBoard(const Rect.fromLTWH(0, 0, 800, 600))
        ..applyPlaced(
          const CanvasStrokeInput(
            id: 'a',
            seq: 1,
            zIndex: 1,
            x: 40,
            y: 40,
            w: 120,
            h: 80,
            points: [],
            width: 0,
            colorKey: 'butter',
            kind: CanvasObjectKind.note,
            text: 'first',
          ),
        )
        ..applyPlaced(
          const CanvasStrokeInput(
            id: 'b',
            seq: 2,
            zIndex: 2,
            x: 240,
            y: 40,
            w: 120,
            h: 80,
            points: [],
            width: 0,
            colorKey: 'butter',
            kind: CanvasObjectKind.note,
            text: 'second',
          ),
        )
        ..setViewport(const Size(800, 600));
      addTearDown(document.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: CanvasBoardKeys(
              document: document,
              tool: CanvasTool.pan,
              onOpenActions: (_) {},
              onPlaceNote: (_) {},
              onPlaceShape: (_) {},
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.bracketRight);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.bracketRight);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.bracketRight);
      expect(document.selectedObjectId.value, 'a');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.bracketLeft);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.bracketLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.bracketLeft);
      expect(document.selectedObjectId.value, 'b');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.escape);
      expect(document.selectedObjectId.value, isNull);

      document.setCamera(const Camera(x: 120, y: 80, zoom: 2));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.digit0);
      final fitted = document.camera;
      document.setCamera(const Camera(x: 120, y: 80, zoom: 2));
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.digit0);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.digit0);
      expect(document.camera.x, 120);
      expect(fitted.x, isNot(120));
    },
  );
}
