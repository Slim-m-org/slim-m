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
}
