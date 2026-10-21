// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Typing in a note's editor is the editor's alone: no board or object key
/// binding fires, so a space types a space and no menu opens.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_note_editor.dart';
import 'package:slimm_design_system/design_system.dart';

import 'canvas_pane_harness.dart';

const _onNote = Offset(415, 15);

Future<CanvasPaneFixture> _openEditor(WidgetTester tester) async {
  final fixture = CanvasPaneFixture()
    ..objects = [canvasNoteJson('note', x: 400, text: 'before')];
  final container = fixture.container();
  addTearDown(container.dispose);
  addTearDown(fixture.events.close);
  await pumpCanvasPane(tester, container);
  await tester.pumpAndSettle();
  await tester.tap(find.bySemanticsLabel('Pan'));
  await tester.pump();
  final at = screenFor(tester, _onNote);
  for (var i = 0; i < 2; i++) {
    final gesture = await tester.startGesture(
      at,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 120));
  }
  expect(find.byType(CanvasNoteEditor), findsOneWidget);
  return fixture;
}

void main() {
  testWidgets('a sentence with spaces types into the note and opens no menu', (
    tester,
  ) async {
    await _openEditor(tester);
    final field = find.descendant(
      of: find.byType(CanvasNoteEditor),
      matching: find.byType(EditableText),
    );
    await tester.tap(field);
    await tester.pump();

    for (final key in [
      LogicalKeyboardKey.keyH,
      LogicalKeyboardKey.space,
      LogicalKeyboardKey.keyI,
      LogicalKeyboardKey.space,
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.bracketRight,
      LogicalKeyboardKey.digit0,
      LogicalKeyboardKey.minus,
    ]) {
      await tester.sendKeyEvent(key);
    }
    await tester.enterText(field, 'the quick brown fox jumps');
    await tester.pumpAndSettle();

    expect(find.text('the quick brown fox jumps'), findsOneWidget);
    expect(find.text('Bring to front'), findsNothing);
    expect(find.byType(CanvasNoteEditor), findsOneWidget);
  });

  testWidgets('the board draws no focus ring while an editor has focus', (
    tester,
  ) async {
    await _openEditor(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(CanvasNoteEditor),
        matching: find.byType(EditableText),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();

    final tokens = Theme.of(
      tester.element(find.byType(CanvasNoteEditor)),
    ).extension<AppTokens>()!;
    final ringed = find.byWidgetPredicate(
      (w) =>
          w is DecoratedBox &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).border is Border &&
          ((w.decoration as BoxDecoration).border! as Border).top.color ==
              tokens.focusRing &&
          ((w.decoration as BoxDecoration).border! as Border).top.width == 2,
    );
    expect(ringed, findsNothing);
  });
}
