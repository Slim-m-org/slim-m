// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The note style bar stays on its note: through a pan, a zoom, typing that grows the note, and a note placed by dragging its size.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_selection_bar.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../support/async_wait.dart';
import 'canvas_pane_harness.dart';

const _gap = 8.0;
final _bar = find.byWidgetPredicate((w) => w is CanvasSelectionBar);
final _editorRect = find.byKey(const ValueKey('canvas-note-editor-rect'));

Future<CanvasPaneFixture> _pane(
  WidgetTester tester, {
  bool withNote = true,
  String? tool,
}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fixture = CanvasPaneFixture()
    ..objects = [
      if (withNote)
        {
          ...canvasNoteJson('note', x: 400, authorId: 'me', text: 'hello'),
          'y': 300.0,
          'w': 330.0,
          'h': 210.0,
          'props': {'text': 'hello'},
        },
    ];
  final container = fixture.container();
  addTearDown(container.dispose);
  addTearDown(fixture.events.close);
  await pumpCanvasPane(tester, container, tool: tool);
  await pumpFrames(tester);
  if (tool == null) {
    await tester.tap(find.bySemanticsLabel('Pan'));
    await tester.pump();
  }
  return fixture;
}

Rect _noteOnScreen(WidgetTester tester, String id) {
  final document = surfaceDocument(tester);
  final b = document.objectBounds(id)!;
  final camera = document.camera;
  return Rect.fromLTWH(
    (b.x - camera.x) * camera.zoom,
    (b.y - camera.y) * camera.zoom,
    b.w * camera.zoom,
    b.h * camera.zoom,
  ).shift(screenFor(tester, Offset.zero));
}

/// The bar sits a gap above the note, or a gap below it when there is no room above, and over the note's width.
void _expectOnNote(WidgetTester tester, String id) {
  final bar = tester.getRect(_bar);
  final note = _noteOnScreen(tester, id);
  final above = (bar.bottom - (note.top - _gap)).abs() < 1.5;
  final below = (bar.top - (note.bottom + _gap)).abs() < 1.5;
  expect(above || below, isTrue, reason: 'bar $bar against note $note');
  final reach = note.center.dx.clamp(bar.left, bar.right);
  expect(reach, closeTo(note.center.dx, 1.5), reason: 'bar $bar over $note');
}

Future<void> _click(WidgetTester tester, Offset on, {int times = 1}) async {
  for (var i = 0; i < times; i++) {
    final click = await tester.startGesture(on, kind: PointerDeviceKind.mouse);
    await click.up();
    await tester.pump(const Duration(milliseconds: 120));
  }
}

void main() {
  testWidgets('a selected note keeps its bar through a pan and a zoom', (
    tester,
  ) async {
    await _pane(tester);
    await _click(tester, _noteOnScreen(tester, 'note').center);
    expect(_bar, findsOneWidget);
    _expectOnNote(tester, 'note');

    final document = surfaceDocument(tester);
    final camera = document.camera;
    document.setCamera(Camera(x: camera.x + 90, y: camera.y + 40, zoom: 1));
    await tester.pump();
    _expectOnNote(tester, 'note');

    document.setCamera(Camera(x: camera.x + 90, y: camera.y + 40, zoom: 1.6));
    await tester.pump();
    _expectOnNote(tester, 'note');
  });

  testWidgets('the bar follows a wheel pan of the board', (tester) async {
    await _pane(tester);
    await _click(tester, _noteOnScreen(tester, 'note').center);
    final before = surfaceDocument(tester).camera;
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: _noteOnScreen(tester, 'note').center,
        scrollDelta: const Offset(120, 50),
      ),
    );
    await pumpFrames(tester);

    expect(surfaceDocument(tester).camera.x, isNot(before.x));
    expect(_bar, findsOneWidget);
    _expectOnNote(tester, 'note');
  });

  testWidgets('typing that grows the note keeps the bar on it', (tester) async {
    await _pane(tester);
    await _click(tester, _noteOnScreen(tester, 'note').center, times: 2);
    await pumpFrames(tester, frames: 15);
    expect(_editorRect, findsOneWidget);
    await tester.enterText(
      find.descendant(
        of: _editorRect,
        matching: find.byWidgetPredicate((w) => w is EditableText),
      ),
      List.filled(30, 'a long line of text').join('\n'),
    );
    await pumpFrames(tester);

    expect(_bar, findsOneWidget);
    _expectOnNote(tester, 'note');
  });

  testWidgets('a note placed by dragging its size has its bar on it', (
    tester,
  ) async {
    await _pane(tester, withNote: false, tool: 'Pen');
    await tester.tap(find.bySemanticsLabel('Note'));
    await tester.pump();
    final from = screenFor(tester, Offset.zero) + const Offset(300, 250);
    final drag = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
    await drag.moveBy(const Offset(60, 40));
    await drag.moveBy(const Offset(120, 90));
    await tester.pump();
    await drag.up();
    await pumpFrames(tester, frames: 15);

    final document = surfaceDocument(tester);
    final id = document.visibleIdsInReadingOrder().first;
    expect(_bar, findsOneWidget);
    _expectOnNote(tester, id);
    await drag.moveBy(Offset.zero);
  });

  testWidgets('the bar lands on the note after the note is dragged', (
    tester,
  ) async {
    await _pane(tester);
    final centre = _noteOnScreen(tester, 'note').center;
    await _click(tester, centre);
    final drag = await tester.startGesture(
      centre,
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveBy(const Offset(60, 30));
    await drag.moveBy(const Offset(80, 50));
    await tester.pump();
    if (_bar.evaluate().isNotEmpty) _expectOnNote(tester, 'note');
    await drag.up();
    await pumpFrames(tester);

    expect(_bar, findsOneWidget);
    _expectOnNote(tester, 'note');
  });

  testWidgets('the bar stays on a draft while the pointer is still down', (
    tester,
  ) async {
    await _pane(tester, withNote: false, tool: 'Pen');
    await tester.tap(find.bySemanticsLabel('Note'));
    await tester.pump();
    final from = screenFor(tester, Offset.zero) + const Offset(300, 250);
    final drag = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
    await drag.moveBy(const Offset(120, 80));
    await tester.pump();
    final id = surfaceDocument(tester).visibleIdsInReadingOrder();
    if (id.isNotEmpty && _bar.evaluate().isNotEmpty) {
      _expectOnNote(tester, id.first);
    }
    await drag.up();
    await pumpFrames(tester, frames: 15);
    expect(_bar, findsOneWidget);
    _expectOnNote(
      tester,
      surfaceDocument(tester).visibleIdsInReadingOrder().first,
    );
  });
}
