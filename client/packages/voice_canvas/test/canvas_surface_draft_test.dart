// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [CanvasSurface]'s `onDraftPoint`/`onDraftEnded`: fired for the same
/// down/move/up gesture `onStroke` is eventually built from, including the
/// second-pointer-cancels-a-draft path `onStroke` itself never sees at all.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

void main() {
  testWidgets('a pen drag reports the first point on down and one per move', (
    tester,
  ) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    final reported = <Offset>[];
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasSurface(
          document: document,
          ink: const Color(0xFFE86A5C),
          onStroke: (_) {},
          onDraftPoint: reported.add,
        ),
      ),
    );
    await tester.pump();

    final gesture = await tester.startGesture(const Offset(20, 20));
    await gesture.moveTo(const Offset(60, 40));
    await gesture.up();
    await tester.pump();

    expect(reported, [const Offset(20, 20), const Offset(60, 40)]);
  });

  testWidgets('onDraftEnded fires once the pointer lifts', (tester) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    var ended = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasSurface(
          document: document,
          ink: const Color(0xFFE86A5C),
          onStroke: (_) {},
          onDraftEnded: () => ended++,
        ),
      ),
    );
    await tester.pump();

    final gesture = await tester.startGesture(const Offset(20, 20));
    await gesture.moveTo(const Offset(60, 40));
    expect(ended, 0, reason: 'not yet - the pointer is still down');
    await gesture.up();
    await tester.pump();

    expect(ended, 1);
  });

  testWidgets(
    'onDraftEnded fires exactly once, and a single-point gesture still commits a one-point stroke',
    (tester) async {
      final document = CanvasDocument();
      addTearDown(document.dispose);
      var ended = 0;
      final strokes = <List<Offset>>[];
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasSurface(
            document: document,
            ink: const Color(0xFFE86A5C),
            onStroke: strokes.add,
            onDraftEnded: () => ended++,
          ),
        ),
      );
      await tester.pump();

      final gesture = await tester.startGesture(const Offset(20, 20));
      await gesture.up();
      await tester.pump();

      expect(
          strokes,
          [
            [const Offset(20, 20)],
          ],
          reason: 'a tap with no move must still leave a dot');
      expect(
        ended,
        1,
        reason: 'a remote viewer must still learn the gesture ended',
      );
    },
  );

  testWidgets(
    'a second pointer cancels the draft and fires onDraftEnded, with no onStroke',
    (tester) async {
      final document = CanvasDocument();
      addTearDown(document.dispose);
      var ended = 0;
      var strokes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasSurface(
            document: document,
            ink: const Color(0xFFE86A5C),
            onStroke: (_) => strokes++,
            onDraftEnded: () => ended++,
          ),
        ),
      );
      await tester.pump();

      final first = await tester.startGesture(const Offset(20, 20));
      await first.moveTo(const Offset(40, 40));
      final second = await tester.startGesture(const Offset(200, 200));
      await tester.pump();

      expect(
        ended,
        1,
        reason:
            'the second pointer cancelling the draft must still tell a remote viewer',
      );

      await first.up();
      await second.up();
      await tester.pump();

      expect(strokes, 0, reason: 'a cancelled draft never becomes a stroke');
      expect(
        ended,
        1,
        reason: 'the cancelled draft was already empty by the time it lifted',
      );
    },
  );

  testWidgets('the eraser and select tools never report a draft point', (
    tester,
  ) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    var points = 0;
    var ended = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasSurface(
          document: document,
          ink: const Color(0xFFE86A5C),
          tool: CanvasTool.eraser,
          onStroke: (_) {},
          onDraftPoint: (_) => points++,
          onDraftEnded: () => ended++,
        ),
      ),
    );
    await tester.pump();

    final gesture = await tester.startGesture(const Offset(20, 20));
    await gesture.moveTo(const Offset(60, 40));
    await gesture.up();
    await tester.pump();

    expect(points, 0);
    expect(ended, 0);
  });

  /// A note or a shape is placed once, not drawn, so there is no draft
  /// worth previewing to anyone else - see `CanvasQuickPlacement`'s own doc
  /// for the app-layer half of this: nothing is sent until the note sheet
  /// submits, so there is nothing on the shared canvas to preview in the
  /// first place.
  testWidgets('the note and shape tools never report a draft point either', (
    tester,
  ) async {
    for (final tool in [CanvasTool.note, CanvasTool.shape]) {
      final document = CanvasDocument();
      addTearDown(document.dispose);
      var points = 0;
      var ended = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasSurface(
            document: document,
            ink: const Color(0xFFE86A5C),
            tool: tool,
            onStroke: (_) {},
            onDraftPoint: (_) => points++,
            onDraftEnded: () => ended++,
          ),
        ),
      );
      await tester.pump();

      final gesture = await tester.startGesture(const Offset(20, 20));
      await gesture.moveTo(const Offset(60, 40));
      await gesture.up();
      await tester.pump();

      expect(points, 0, reason: 'kind: $tool');
      expect(ended, 0, reason: 'kind: $tool');
    }
  });

  testWidgets(
    'onDraftCancel fires when a second pointer cancels an in-flight draft',
    (tester) async {
      final document = CanvasDocument();
      addTearDown(document.dispose);
      var ended = 0;
      var cancelled = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasSurface(
            document: document,
            ink: const Color(0xFFE86A5C),
            onStroke: (_) {},
            onDraftEnded: () => ended++,
            onDraftCancel: () => cancelled++,
          ),
        ),
      );
      await tester.pump();

      final first = await tester.startGesture(const Offset(20, 20));
      await first.moveTo(const Offset(40, 40));
      final second = await tester.startGesture(const Offset(200, 200));
      await tester.pump();

      expect(cancelled, 1);
      expect(ended, 0);

      await first.up();
      await second.up();
      await tester.pump();
      expect(cancelled, 1);
      expect(ended, 0);
    },
  );
}
