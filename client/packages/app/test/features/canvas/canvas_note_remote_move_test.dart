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
}
