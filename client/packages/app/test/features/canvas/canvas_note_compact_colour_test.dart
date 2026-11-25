// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The colour sheet at phone width while a note is typed in: choosing a colour or dismissing it keeps the edit and the keyboard.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_text_focus.dart';

import '../../support/async_wait.dart';
import 'canvas_pane_harness.dart';
import 'canvas_text_pane_support.dart';

const _phone = Size(390, 800);
const _onNote = Offset(300, 200);
final _editorRect = find.byKey(const ValueKey('canvas-note-editor-rect'));

Future<void> _doubleClick(WidgetTester tester, Offset world) async {
  for (var i = 0; i < 2; i++) {
    final camera = surfaceDocument(tester).camera;
    final click = await tester.startGesture(
      screenFor(
        tester,
        Offset(
          (world.dx - camera.x) * camera.zoom,
          (world.dy - camera.y) * camera.zoom,
        ),
      ),
      kind: PointerDeviceKind.mouse,
    );
    await click.up();
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Future<CanvasPaneFixture> _typeWithSheetOpen(WidgetTester tester) async {
  tester.view.physicalSize = _phone;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fixture = CanvasPaneFixture()
    ..objects = [
      {
        ...canvasNoteJson('note', x: 100, authorId: 'me', text: 'before'),
        'y': 100.0,
        'w': 330.0,
        'h': 210.0,
        'props': {'text': 'before'},
      },
    ];
  final container = fixture.container();
  addTearDown(container.dispose);
  addTearDown(fixture.events.close);
  await pumpCanvasPane(tester, container);
  await pumpFrames(tester);
  await tester.tap(find.bySemanticsLabel('Pan'));
  await tester.pump();
  await _doubleClick(tester, _onNote);
  await pumpFrames(tester, frames: 15);
  await tester.enterText(
    find.descendant(
      of: _editorRect,
      matching: find.byWidgetPredicate((w) => w is EditableText),
    ),
    'typed',
  );
  await pumpFrames(tester);
  await tester.tap(find.byTooltip('Colours'));
  await pumpFrames(tester);
  return fixture;
}

void main() {
  testWidgets('picking a colour keeps the edit, the text and the keyboard', (
    tester,
  ) async {
    final fixture = await _typeWithSheetOpen(tester);
    expect(find.byTooltip('Default fill'), findsOneWidget);

    await tester.tap(find.byTooltip('Default fill'));
    await pumpFrames(tester);

    expect(_editorRect, findsOneWidget);
    expect(find.text('typed'), findsOneWidget);
    expect(fixture.postedOps.where((op) => op['kind'] == 'edit'), isEmpty);
    expect(textInputHasFocus(), isTrue);
  });

  testWidgets(
    'tapping off the sheet keeps the edit, the text and the keyboard',
    (tester) async {
      final fixture = await _typeWithSheetOpen(tester);

      await tester.tapAt(const Offset(195, 40));
      await pumpFrames(tester);

      expect(find.byTooltip('Default fill'), findsNothing);
      expect(_editorRect, findsOneWidget);
      expect(find.text('typed'), findsOneWidget);
      expect(fixture.postedOps.where((op) => op['kind'] == 'edit'), isEmpty);
      expect(textInputHasFocus(), isTrue);
    },
  );

  testWidgets('a text box keeps the keyboard when its colour sheet closes', (
    tester,
  ) async {
    tester.view.physicalSize = _phone;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await openPane(
      tester,
      objects: [
        {...textBoxJson('box'), 'x': 100.0, 'y': 300.0, 'w': 200.0},
      ],
    );
    await tester.tap(find.bySemanticsLabel('Pan'));
    await tester.pump();
    await _doubleClick(tester, const Offset(150, 315));
    await pumpFrames(tester, frames: 15);
    await tester.enterText(field, 'typed');
    await pumpFrames(tester);
    await tester.tap(find.byTooltip('Text colour'));
    await pumpFrames(tester);

    await tester.tapAt(const Offset(195, 40));
    await pumpFrames(tester);

    expect(editor, findsOneWidget);
    expect(textInputHasFocus(), isTrue);
  });
}
