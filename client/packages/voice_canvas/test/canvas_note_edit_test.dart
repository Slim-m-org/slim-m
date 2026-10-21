// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Editing a placed note: the document swaps its text, the painter lays out
/// the caller's spans, and the select tool reports a tap but not a drag.
library;

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/src/canvas_painters.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

CanvasStrokeInput _note(String id, String text, CanvasObjectKind kind) =>
    CanvasStrokeInput(
      id: id,
      seq: 0,
      zIndex: 0,
      x: 0,
      y: 0,
      w: 220,
      h: 140,
      points: const [],
      width: 0,
      colorKey: 'annotation',
      kind: kind,
      text: text,
    );

void main() {
  test('setNoteText replaces a live note and reports it back', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    addTearDown(document.dispose);
    document.applyPlaced(_note('n', 'first', CanvasObjectKind.note));

    expect(document.noteTextOf('n'), 'first');
    expect(document.setNoteText('n', 'second'), isTrue);
    expect(document.noteTextOf('n'), 'second');
  });

  test('setNoteText refuses a missing, removed or non-note object', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    addTearDown(document.dispose);
    document
      ..applyPlaced(_note('n', 'x', CanvasObjectKind.note))
      ..applyPlaced(_note('s', 'x', CanvasObjectKind.shape));

    expect(document.setNoteText('missing', 'y'), isFalse);
    expect(document.setNoteText('s', 'y'), isFalse);
    expect(document.noteTextOf('s'), isNull);
    document.removeObject('n');
    expect(document.setNoteText('n', 'y'), isFalse);
    expect(document.noteTextOf('n'), isNull);
  });

  testWidgets('the painter lays out the spans the builder returns', (
    tester,
  ) async {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    addTearDown(document.dispose);
    document
      ..applyPlaced(_note('n', 'hello **there**', CanvasObjectKind.note))
      ..refresh();
    final seen = <String>[];
    final painter = StrokePainter(
      document: document,
      ink: const Color(0xFF1A1A1A),
      noteSpans: (text, base) {
        seen.add(text);
        return TextSpan(text: 'styled', style: base);
      },
    );
    final recorder = PictureRecorder();
    painter.paint(Canvas(recorder), const Size(800, 600));
    recorder.endRecording().dispose();
    painter.dispose();

    expect(seen, ['hello **there**']);
  });

  testWidgets('a tap with the select tool reports its point and pointer kind', (
    tester,
  ) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    final taps = <(Offset, PointerDeviceKind)>[];
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasSurface(
          document: document,
          ink: const Color(0xFFE86A5C),
          tool: CanvasTool.pan,
          onStroke: (_) {},
          onSelectTap: (world, kind) => taps.add((world, kind)),
        ),
      ),
    );
    await tester.pump();
    document.setCamera(const Camera(x: 100, y: 50, zoom: 1));
    await tester.pump();

    await tester.tapAt(const Offset(20, 20));
    await tester.pump();
    final mouse = await tester.startGesture(
      const Offset(30, 30),
      kind: PointerDeviceKind.mouse,
    );
    await mouse.up();
    await tester.pump();

    expect(taps, [
      (const Offset(120, 70), PointerDeviceKind.touch),
      (const Offset(130, 80), PointerDeviceKind.mouse),
    ]);
  });

  testWidgets('a drag with the select tool is not a tap', (tester) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    var taps = 0;
    var ends = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasSurface(
          document: document,
          ink: const Color(0xFFE86A5C),
          tool: CanvasTool.pan,
          onStroke: (_) {},
          onSelectEnd: () => ends++,
          onSelectTap: (point, kind) => taps++,
        ),
      ),
    );
    await tester.pump();

    final gesture = await tester.startGesture(const Offset(20, 20));
    await gesture.moveTo(const Offset(60, 40));
    await gesture.up();
    await tester.pump();

    expect(ends, 1);
    expect(taps, 0);
  });
}
