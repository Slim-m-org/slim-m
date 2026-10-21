// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Per-tool pointer behaviour for [CanvasSurface]: the eraser, select, note
/// and shape tools, and the pinch-cancellation every placement tool and the
/// eraser share. Split out of `canvas_surface_test.dart`, which keeps the
/// surface's base plumbing (camera moves, a plain pen drag, hover reporting,
/// the cursor layer), once this half crossed the file budget on its own.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

void main() {
  testWidgets('the eraser tool reports world points and commits no ink', (
    tester,
  ) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    var strokes = 0;
    final erased = <Offset>[];
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasSurface(
          document: document,
          ink: const Color(0xFFE86A5C),
          tool: CanvasTool.eraser,
          onStroke: (_) => strokes++,
          onErase: erased.add,
        ),
      ),
    );
    await tester.pump();
    document.setCamera(const Camera(x: 100, y: 50, zoom: 1));
    await tester.pump();

    final gesture = await tester.startGesture(const Offset(20, 20));
    await gesture.moveTo(const Offset(60, 40));
    await gesture.up();
    await tester.pump();

    expect(strokes, 0, reason: 'the eraser must never commit a pen stroke');
    expect(erased, [const Offset(120, 70), const Offset(160, 90)]);
  });

  testWidgets(
    'onEraseEnd fires once, when the last pointer lifts, not per move',
    (tester) async {
      final document = CanvasDocument();
      addTearDown(document.dispose);
      var ends = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasSurface(
            document: document,
            ink: const Color(0xFFE86A5C),
            tool: CanvasTool.eraser,
            onStroke: (_) {},
            onErase: (_) {},
            onEraseEnd: () => ends++,
          ),
        ),
      );
      await tester.pump();

      final gesture = await tester.startGesture(const Offset(20, 20));
      await gesture.moveTo(const Offset(60, 40));
      await gesture.moveTo(const Offset(90, 70));
      expect(ends, 0, reason: 'a move is not the end of the gesture');
      await gesture.up();
      await tester.pump();

      expect(ends, 1);
    },
  );

  testWidgets('a disabled eraser reports nothing', (tester) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    var erased = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasSurface(
          document: document,
          ink: const Color(0xFFE86A5C),
          tool: CanvasTool.eraser,
          enabled: false,
          onStroke: (_) {},
          onErase: (_) => erased++,
        ),
      ),
    );
    await tester.pump();

    final gesture = await tester.startGesture(const Offset(20, 20));
    await gesture.moveTo(const Offset(80, 80));
    await gesture.up();
    await tester.pump();

    expect(erased, 0);
  });

  testWidgets('a tap-only erase with no move still reports its one point', (
    tester,
  ) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    final erased = <Offset>[];
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasSurface(
          document: document,
          ink: const Color(0xFFE86A5C),
          tool: CanvasTool.eraser,
          onStroke: (_) {},
          onErase: erased.add,
        ),
      ),
    );
    await tester.pump();

    final gesture = await tester.startGesture(const Offset(20, 20));
    await gesture.up();
    await tester.pump();

    expect(erased, [const Offset(20, 20)]);
  });

  /// The same collision `_pendingPlacementWorld` already dodges for note and
  /// shape (see the pinch-cancellation test below): the eraser's own
  /// pointer-down point is deferred the same way, so a pinch's bare first
  /// finger cancels rather than erasing whatever it happened to land on.
  testWidgets(
    'a second pointer cancels a pending erase point, with nothing erased',
    (tester) async {
      final document = CanvasDocument();
      addTearDown(document.dispose);
      final erased = <Offset>[];
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasSurface(
            document: document,
            ink: const Color(0xFFE86A5C),
            tool: CanvasTool.eraser,
            onStroke: (_) {},
            onErase: erased.add,
          ),
        ),
      );
      await tester.pump();

      final first = await tester.startGesture(const Offset(20, 20));
      final second = await tester.startGesture(const Offset(200, 200));
      await tester.pump();
      await first.up();
      await second.up();
      await tester.pump();

      expect(erased, isEmpty, reason: 'the pinch attempt cancelled this one');
    },
  );

  testWidgets(
    'a real erase drag still reports every point live after a would-be '
    'pinch on an earlier independent gesture',
    (tester) async {
      final document = CanvasDocument();
      addTearDown(document.dispose);
      final erased = <Offset>[];
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasSurface(
            document: document,
            ink: const Color(0xFFE86A5C),
            tool: CanvasTool.eraser,
            onStroke: (_) {},
            onErase: erased.add,
          ),
        ),
      );
      await tester.pump();

      final first = await tester.startGesture(const Offset(20, 20));
      final second = await tester.startGesture(const Offset(200, 200));
      await tester.pump();
      await first.up();
      await second.up();
      await tester.pump();
      expect(erased, isEmpty);

      final drag = await tester.startGesture(const Offset(40, 40));
      await drag.moveTo(const Offset(80, 80));
      await drag.up();
      await tester.pump();

      expect(erased, [const Offset(40, 40), const Offset(80, 80)]);
    },
  );

  testWidgets('the select tool reports world points and commits no ink', (
    tester,
  ) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    var strokes = 0;
    final starts = <Offset>[];
    final drags = <Offset>[];
    var ends = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasSurface(
          document: document,
          ink: const Color(0xFFE86A5C),
          tool: CanvasTool.pan,
          onStroke: (_) => strokes++,
          onSelectStart: starts.add,
          onSelectDrag: drags.add,
          onSelectEnd: () => ends++,
        ),
      ),
    );
    await tester.pump();
    document.setCamera(const Camera(x: 100, y: 50, zoom: 1));
    await tester.pump();

    final gesture = await tester.startGesture(const Offset(20, 20));
    await gesture.moveTo(const Offset(60, 40));
    await gesture.up();
    await tester.pump();

    expect(strokes, 0, reason: 'select must never commit a pen stroke');
    expect(starts, [const Offset(120, 70)]);
    expect(drags, [const Offset(160, 90)]);
    expect(ends, 1);
  });

  testWidgets(
    'note and shape tools each place once per tap, at the pointer-down point, no drag needed',
    (tester) async {
      final document = CanvasDocument();
      addTearDown(document.dispose);
      final notes = <Offset>[];
      final shapes = <Offset>[];
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasSurface(
            document: document,
            ink: const Color(0xFFE86A5C),
            tool: CanvasTool.note,
            onStroke: (_) {},
            onNotePlace: notes.add,
            onShapePlace: (world, _, {flipX = false, flipY = false}) =>
                shapes.add(world),
          ),
        ),
      );
      await tester.pump();

      final gesture = await tester.startGesture(const Offset(20, 20));
      await gesture.moveTo(const Offset(60, 40));
      expect(notes, isEmpty, reason: 'not yet - the pointer is still down');
      await gesture.up();
      await tester.pump();

      expect(notes, [const Offset(20, 20)]);
      expect(shapes, isEmpty, reason: 'the shape tool was never selected');
    },
  );

  /// Panning and zooming this surface are two-pointer-only (see
  /// `_scaleUpdate`'s own pointer-count guard), so a two-finger pinch always
  /// begins with exactly one finger down before the second arrives. Without
  /// this cancellation, that first finger would drop an unwanted note or
  /// shape every time somebody tried to pinch-zoom with either tool active.
  testWidgets(
    'a second pointer cancels a pending note or shape placement, with nothing placed',
    (tester) async {
      for (final tool in [CanvasTool.note, CanvasTool.shape]) {
        final document = CanvasDocument();
        addTearDown(document.dispose);
        final notes = <Offset>[];
        final shapes = <Offset>[];
        await tester.pumpWidget(
          MaterialApp(
            home: CanvasSurface(
              document: document,
              ink: const Color(0xFFE86A5C),
              tool: tool,
              onStroke: (_) {},
              onNotePlace: notes.add,
              onShapePlace: (world, _, {flipX = false, flipY = false}) =>
                  shapes.add(world),
            ),
          ),
        );
        await tester.pump();

        final first = await tester.startGesture(const Offset(20, 20));
        final second = await tester.startGesture(const Offset(200, 200));
        await tester.pump();
        await first.up();
        await second.up();
        await tester.pump();

        expect(notes, isEmpty, reason: 'kind: $tool');
        expect(shapes, isEmpty, reason: 'kind: $tool');
      }
    },
  );

  testWidgets(
    'a tap that survives a would-be pinch on a later independent gesture still places',
    (tester) async {
      final document = CanvasDocument();
      addTearDown(document.dispose);
      final notes = <Offset>[];
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasSurface(
            document: document,
            ink: const Color(0xFFE86A5C),
            tool: CanvasTool.note,
            onStroke: (_) {},
            onNotePlace: notes.add,
          ),
        ),
      );
      await tester.pump();

      final first = await tester.startGesture(const Offset(20, 20));
      final second = await tester.startGesture(const Offset(200, 200));
      await tester.pump();
      await first.up();
      await second.up();
      await tester.pump();
      expect(notes, isEmpty, reason: 'the pinch attempt cancelled this one');

      final ordinary = await tester.startGesture(const Offset(40, 40));
      await ordinary.up();
      await tester.pump();

      expect(notes, [const Offset(40, 40)]);
    },
  );
}
