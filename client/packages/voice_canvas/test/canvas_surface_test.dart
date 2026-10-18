// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Phase 5 rebuild gate, run against the shipped surface rather than
/// against a benchmark fixture.
///
/// `canvas_scene_test.dart` proves the shape in isolation. This proves the
/// real widget kept it: a camera move must repaint and rebuild nothing, and
/// the painters must be the same objects frame after frame.
///
/// Per-tool pointer behaviour (eraser, select, note, shape, and the pinch
/// cancellation they share) is `canvas_surface_gestures_test.dart`, split out
/// once this file crossed the file budget.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

void main() {
  testWidgets('twenty camera moves rebuild no widget in the surface', (
    tester,
  ) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasSurface(
          document: document,
          ink: const Color(0xFFE86A5C),
          onStroke: (_) {},
        ),
      ),
    );
    await tester.pump();

    final before =
        tester.widgetList<CustomPaint>(find.byType(CustomPaint)).toList();
    expect(before, isNotEmpty);

    for (var i = 0; i < 20; i++) {
      document.setCamera(Camera(x: i.toDouble(), y: 0, zoom: 1));
      await tester.pump();
    }

    final after =
        tester.widgetList<CustomPaint>(find.byType(CustomPaint)).toList();
    expect(after.length, before.length);
    for (var i = 0; i < before.length; i++) {
      expect(
        identical(before[i], after[i]),
        isTrue,
        reason: 'a rebuild would have constructed a new CustomPaint widget',
      );
    }
  });

  testWidgets('a drag becomes one stroke in world coordinates', (tester) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    List<Offset>? committed;
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasSurface(
          document: document,
          ink: const Color(0xFFE86A5C),
          onStroke: (points) => committed = points,
        ),
      ),
    );
    await tester.pump();
    document.setCamera(const Camera(x: 100, y: 50, zoom: 1));
    await tester.pump();

    final gesture = await tester.startGesture(const Offset(20, 20));
    await gesture.moveTo(const Offset(60, 40));
    await gesture.moveTo(const Offset(120, 90));
    await gesture.up();
    await tester.pump();

    expect(committed, isNotNull);
    expect(committed!.first, const Offset(120, 70));
    expect(committed!.last, const Offset(220, 140));
  });

  /// A timed-out member keeps seeing the canvas and cannot add to it, which is
  /// exactly the behaviour `USE_CANVAS` cannot express on its own.
  testWidgets('a disabled surface still pans and never commits ink', (
    tester,
  ) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    var strokes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasSurface(
          document: document,
          ink: const Color(0xFFE86A5C),
          enabled: false,
          onStroke: (_) => strokes++,
        ),
      ),
    );
    await tester.pump();

    final gesture = await tester.startGesture(const Offset(20, 20));
    await gesture.moveTo(const Offset(80, 80));
    await gesture.up();
    await tester.pump();

    expect(strokes, 0);
  });

  testWidgets(
      'onPointerMoved reports world points during a hover, no button down', (
    tester,
  ) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    final moved = <Offset>[];
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasSurface(
          document: document,
          ink: const Color(0xFFE86A5C),
          onStroke: (_) {},
          onPointerMoved: moved.add,
        ),
      ),
    );
    await tester.pump();
    document.setCamera(const Camera(x: 100, y: 50, zoom: 1));
    await tester.pump();

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: const Offset(20, 20));
    await tester.pump();
    await gesture.moveTo(const Offset(60, 40));
    await tester.pump();

    expect(moved, contains(const Offset(160, 90)));
  });

  testWidgets('onPointerMoved also reports positions while drawing', (
    tester,
  ) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    final moved = <Offset>[];
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasSurface(
          document: document,
          ink: const Color(0xFFE86A5C),
          onStroke: (_) {},
          onPointerMoved: moved.add,
        ),
      ),
    );
    await tester.pump();

    final gesture = await tester.startGesture(const Offset(20, 20));
    await gesture.moveTo(const Offset(60, 40));
    await gesture.up();
    await tester.pump();

    expect(moved, [const Offset(20, 20), const Offset(60, 40)]);
  });

  testWidgets('lifting a touch reports the pointer left, a mouse does not', (
    tester,
  ) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    var left = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasSurface(
          document: document,
          ink: const Color(0xFFE86A5C),
          onStroke: (_) {},
          onPointerLeft: () => left++,
        ),
      ),
    );
    await tester.pump();

    final mouse = await tester.startGesture(
      const Offset(20, 20),
      kind: PointerDeviceKind.mouse,
    );
    await mouse.up();
    expect(left, 0, reason: 'a mouse is still hovering after a click');

    final touch = await tester.startGesture(const Offset(20, 20));
    await touch.up();
    expect(left, 1);
  });

  testWidgets('a mouse leaving the surface reports the pointer left', (
    tester,
  ) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    var left = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 100,
            height: 100,
            child: CanvasSurface(
              document: document,
              ink: const Color(0xFFE86A5C),
              onStroke: (_) {},
              onPointerLeft: () => left++,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byType(CanvasSurface)));
    expect(left, 0);
    await mouse.moveTo(const Offset(5, 5));
    expect(left, 1);
  });

  testWidgets('a cursor layer paints only when cursors is supplied', (
    tester,
  ) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    final cursors = CanvasCursors();
    addTearDown(cursors.dispose);
    cursors.upsert(id: 'alice', x: 0, y: 0, label: 'Alice', colorIndex: 0);

    await tester.pumpWidget(
      MaterialApp(
        home: CanvasSurface(
          document: document,
          ink: const Color(0xFFE86A5C),
          onStroke: (_) {},
          cursors: cursors,
          cursorColors: const [Color(0xFFE0699A)],
        ),
      ),
    );
    await tester.pump();

    expect(
      tester.widgetList<CustomPaint>(find.byType(CustomPaint)).any(
            (paint) => paint.painter is CursorPainter,
          ),
      isTrue,
    );
  });

  testWidgets('no cursor layer exists when cursors is null', (tester) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: CanvasSurface(
          document: document,
          ink: const Color(0xFFE86A5C),
          onStroke: (_) {},
        ),
      ),
    );
    await tester.pump();

    expect(
      tester.widgetList<CustomPaint>(find.byType(CustomPaint)).any(
            (paint) => paint.painter is CursorPainter,
          ),
      isFalse,
    );
  });

  group('a cancelled pointer', () {
    Future<List<List<Offset>>> draw(
      WidgetTester tester, {
      required bool cancel,
    }) async {
      final document = CanvasDocument();
      addTearDown(document.dispose);
      final strokes = <List<Offset>>[];
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasSurface(
            document: document,
            ink: const Color(0xFFE86A5C),
            onStroke: strokes.add,
          ),
        ),
      );
      await tester.pump();
      final gesture = await tester.startGesture(const Offset(20, 20));
      await gesture.moveTo(const Offset(80, 80));
      if (cancel) {
        await gesture.cancel();
      } else {
        await gesture.up();
      }
      await tester.pump();
      return strokes;
    }

    testWidgets('a pointer that lifts normally still commits (control)', (
      tester,
    ) async {
      expect(await draw(tester, cancel: false), hasLength(1));
    });

    testWidgets('does not commit a pen stroke', (tester) async {
      expect(await draw(tester, cancel: true), isEmpty);
    });
  });
}
