// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A note being typed in follows a remote move, and finishing the edit never drags it back.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../support/async_wait.dart';
import 'canvas_pane_harness.dart';

Map<String, dynamic> _note() => {
  ...canvasNoteJson('note', x: 100, text: 'before'),
  'y': 100.0,
  'w': 330.0,
  'h': 60.0,
};

const _onNote = Offset(300, 130);
final _editorRect = find.byKey(const ValueKey('canvas-note-editor-rect'));

Future<void> _click(WidgetTester tester, Offset world) async {
  final gesture = await tester.startGesture(
    screenFor(tester, world),
    kind: PointerDeviceKind.mouse,
  );
  await gesture.up();
  await tester.pump(const Duration(milliseconds: 120));
}

Future<(CanvasPaneFixture, CanvasDocument)> _typing(
  WidgetTester tester,
  String text,
) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fixture = CanvasPaneFixture()..objects = [_note()];
  final container = fixture.container();
  addTearDown(container.dispose);
  addTearDown(fixture.events.close);
  await pumpCanvasPane(tester, container, tool: null);
  await pumpFrames(tester);
  await tester.tap(find.bySemanticsLabel('Pan'));
  await tester.pump();
  await _click(tester, _onNote);
  await _click(tester, _onNote);
  await pumpFrames(tester, frames: 15);
  await tester.enterText(
    find.descendant(
      of: _editorRect,
      matching: find.byWidgetPredicate((w) => w is EditableText),
    ),
    text,
  );
  await tester.pump();
  return (fixture, surfaceDocument(tester));
}

void main() {
  testWidgets('a remote move while typing survives the commit', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fixture = CanvasPaneFixture()..objects = [_note()];
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container, tool: null);
    await pumpFrames(tester);
    await tester.tap(find.bySemanticsLabel('Pan'));
    await tester.pump();
    final document = surfaceDocument(tester);

    await _click(tester, _onNote);
    await _click(tester, _onNote);
    await pumpFrames(tester, frames: 15);
    expect(_editorRect, findsOneWidget);
    await tester.enterText(
      find.descendant(
        of: _editorRect,
        matching: find.byWidgetPredicate((w) => w is EditableText),
      ),
      List.generate(8, (i) => 'line $i').join('\n'),
    );
    await tester.pump();
    final grown = document.objectBounds('note')!;
    expect(grown.h, greaterThan(60));

    document.moveObject('note', 600, 400, grown.w, grown.h);
    document.refresh();
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await pumpFrames(tester);

    final now = document.objectBounds('note')!;
    expect((now.x, now.y), (600.0, 400.0));
    for (final op in fixture.postedOps.where((o) => o['kind'] == 'move')) {
      expect((op['x'], op['y']), (600.0, 400.0));
    }
  });

  testWidgets('closing the pane sends what was typed', (tester) async {
    final (fixture, _) = await _typing(tester, 'one more line');
    await tester.pumpWidget(const SizedBox());
    await pumpFrames(tester, frames: 20);

    final edits = fixture.postedOps.where((o) => o['kind'] == 'edit');
    expect(edits, hasLength(1));
    expect((edits.single['props'] as Map)['text'], 'one more line');
  });

  testWidgets('a hard reset mid draft keeps the typed text', (tester) async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container, tool: 'Note');
    await pumpFrames(tester);
    await _click(tester, const Offset(300, 300));
    await pumpFrames(tester, frames: 15);
    expect(_editorRect, findsOneWidget);
    await tester.enterText(
      find.descendant(
        of: _editorRect,
        matching: find.byWidgetPredicate((w) => w is EditableText),
      ),
      'typed before the reset',
    );
    await tester.pump();

    surfaceDocument(tester)
      ..reset()
      ..refresh();
    await pumpFrames(tester, frames: 20);

    expect(_editorRect, findsOneWidget);
    expect(find.text('typed before the reset'), findsOneWidget);
  });

  testWidgets('closing the pane places a typed draft', (tester) async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container, tool: 'Note');
    await pumpFrames(tester);
    await _click(tester, const Offset(300, 300));
    await pumpFrames(tester, frames: 15);
    await tester.enterText(
      find.descendant(
        of: _editorRect,
        matching: find.byWidgetPredicate((w) => w is EditableText),
      ),
      'left on the way out',
    );
    await tester.pump();

    await tester.pumpWidget(const SizedBox());
    await pumpFrames(tester, frames: 20);

    final placed = fixture.posted.where((p) => p['kind'] == 'note');
    expect(placed, hasLength(1));
    expect((placed.single['props'] as Map)['text'], 'left on the way out');
  });
}
