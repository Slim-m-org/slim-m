// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A text box typed where it sits: the box is the field, and a bar carries its size and colour.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_selection_bar.dart';
import 'package:slimm_design_system/design_system.dart' show AppTokens;
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../support/async_wait.dart';
import 'canvas_pane_harness.dart';
import 'canvas_text_pane_support.dart';

void main() {
  testWidgets('the text is typed in a field with no Save or Cancel button', (
    tester,
  ) async {
    await openPane(tester);
    await placeWithTool(tester, const Offset(150, 150));

    expect(find.text('Save'), findsNothing);
    expect(find.text('Cancel'), findsNothing);
    expect(editor, findsOneWidget);
  });

  group('the box is the field', () {
    Future<void> openBox(WidgetTester tester) async {
      await openPane(tester, objects: [textBoxJson('box')]);
      await tester.tap(find.bySemanticsLabel('Pan'));
      await tester.pump();
      await fingerTapTwice(tester, const Offset(415, 20));
    }

    for (final zoom in [0.5, 1.0, 2.0]) {
      testWidgets('its rect equals the box rect at zoom $zoom', (tester) async {
        await openPane(tester, objects: [textBoxJson('box')]);
        surfaceDocument(
          tester,
        ).setCamera(Camera(x: zoom > 1 ? 350 : 0, zoom: zoom));
        await tester.pump();
        await tester.tap(find.bySemanticsLabel('Pan'));
        await tester.pump();
        final at = boxOnScreen(tester, 'box').center;
        await tester.tapAt(at);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tapAt(at);
        await pumpFrames(tester);

        expect(
          tester.getRect(find.byKey(const ValueKey('canvas-text-editor-rect'))),
          boxOnScreen(tester, 'box'),
        );
      });
    }

    testWidgets('the default colour is typed in the theme text colour', (
      tester,
    ) async {
      await openBox(tester);

      final style = tester.widget<TextField>(field).style!;
      expect(style.color, AppTokens.dark.textPrimary);
    });

    testWidgets('the board leaves the box text out while it is typed', (
      tester,
    ) async {
      await openBox(tester);

      expect(surfaceDocument(tester).editingObjectId.value, 'box');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await pumpFrames(tester);
      expect(surfaceDocument(tester).editingObjectId.value, isNull);
    });

    testWidgets('a press outside commits one edit', (tester) async {
      final fixture = await openPane(tester, objects: [textBoxJson('box')]);
      await tester.tap(find.bySemanticsLabel('Pan'));
      await tester.pump();
      await fingerTapTwice(tester, const Offset(415, 20));
      await tester.enterText(field, 'moved on');

      await tester.tap(find.bySemanticsLabel('Pen'));
      await tester.pump(const Duration(milliseconds: 400));

      final edits = fixture.postedOps.where((op) => op['kind'] == 'edit');
      expect(edits, hasLength(1));
      expect((edits.single['props'] as Map)['text'], 'moved on');
    });
  });

  group('the style bar over a text box', () {
    testWidgets('one tap on a size sends one edit, and undo reverses it', (
      tester,
    ) async {
      final fixture = await openPane(tester, objects: [textBoxJson('box')]);
      await tester.tap(find.bySemanticsLabel('Pan'));
      await tester.pump();
      await tester.tapAt(screenFor(tester, const Offset(415, 20)));
      await pumpFrames(tester);

      await tester.tap(find.text('L'));
      await pumpFrames(tester);

      final edits = fixture.postedOps.where((op) => op['kind'] == 'edit');
      expect(edits, hasLength(1));
      expect(edits.single['props'], {
        'text': 'before',
        'size': 'large',
        'color': 'ink',
      });
      await tester.tap(find.bySemanticsLabel('Undo'));
      await pumpFrames(tester);
      expect(surfaceDocument(tester).textBoxOf('box')?.size, 'medium');
    });

    testWidgets("someone else's box shows no bar to a plain member", (
      tester,
    ) async {
      await openPane(tester, objects: [textBoxJson('box', authorId: 'other')]);
      await tester.tap(find.bySemanticsLabel('Pan'));
      await tester.pump();
      await tester.tapAt(screenFor(tester, const Offset(415, 20)));
      await pumpFrames(tester);

      expect(find.text('L'), findsNothing);
    });

    testWidgets('a bar slid to the top left sits above the view and zoom '
        'readouts', (tester) async {
      await openPane(
        tester,
        objects: [
          {...textBoxJson('box'), 'x': 20.0, 'y': 60.0},
        ],
      );
      await tester.tap(find.bySemanticsLabel('Pan'));
      await tester.pump();
      await fingerTapTwice(tester, const Offset(40, 75));

      final bar = tester.getRect(find.byType(CanvasSelectionBar));
      final chip = tester.getRect(
        find.bySemanticsLabel(RegExp('^Shared view')),
      );
      final overlap = bar.intersect(chip);
      expect(overlap.isEmpty, isFalse, reason: 'the fixture must collide');
      final hit = tester.hitTestOnBinding(overlap.center);
      expect(
        hit.path.any(
          (e) =>
              e.target is RenderBox && (e.target as RenderBox).size == bar.size,
        ),
        isTrue,
      );
    });
  });
}
