// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One gesture has one owner: the first accepted pointer, under the tool and
/// camera it began with. A cancel never commits, a second finger makes a
/// pinch, a stylus outranks a resting palm, and a foreign camera move or a
/// tool change ends the gesture instead of relocating it.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

class _Calls {
  final strokes = <List<Offset>>[];
  final erased = <Offset>[];
  int eraseEnds = 0;
  int eraseCancels = 0;
  int selectStarts = 0;
  int selectEnds = 0;
  int selectCancels = 0;
  final taps = <Offset>[];
  int draftEnds = 0;
}

Future<_Calls> _pump(
  WidgetTester tester,
  CanvasDocument document, {
  CanvasTool tool = CanvasTool.pen,
  ValueNotifier<CanvasTool>? tools,
}) async {
  final calls = _Calls();
  Widget surface(CanvasTool value) => CanvasSurface(
        document: document,
        ink: const Color(0xFFE86A5C),
        tool: value,
        onStroke: calls.strokes.add,
        onErase: calls.erased.add,
        onEraseEnd: () => calls.eraseEnds++,
        onEraseCancel: () => calls.eraseCancels++,
        onSelectStart: (_) => calls.selectStarts++,
        onSelectEnd: () => calls.selectEnds++,
        onSelectCancel: () => calls.selectCancels++,
        onSelectTap: (world, _) => calls.taps.add(world),
        onDraftEnded: () => calls.draftEnds++,
      );
  await tester.pumpWidget(
    MaterialApp(
      home: tools == null
          ? surface(tool)
          : ValueListenableBuilder<CanvasTool>(
              valueListenable: tools,
              builder: (context, value, child) => surface(value),
            ),
    ),
  );
  await tester.pump();
  return calls;
}

void main() {
  late CanvasDocument document;

  setUp(() => document = CanvasDocument());
  tearDown(() => document.dispose());

  group('a cancelled pointer commits nothing', () {
    testWidgets('an erase asks the caller to bring back what it hid', (
      tester,
    ) async {
      final calls = await _pump(tester, document, tool: CanvasTool.eraser);
      final gesture = await tester.startGesture(const Offset(20, 20));
      await gesture.moveTo(const Offset(60, 40));
      await gesture.cancel();
      await tester.pump();

      expect(calls.eraseCancels, 1);
      expect(calls.eraseEnds, 0);
    });

    testWidgets('a drag asks the caller to put the object back', (
      tester,
    ) async {
      final calls = await _pump(tester, document, tool: CanvasTool.pan);
      final gesture = await tester.startGesture(const Offset(20, 20));
      await gesture.moveTo(const Offset(60, 40));
      await gesture.cancel();
      await tester.pump();

      expect(calls.selectCancels, 1);
      expect(calls.selectEnds, 0);
      expect(calls.taps, isEmpty);
    });

    testWidgets('a stroke in progress is dropped, not saved', (tester) async {
      final calls = await _pump(tester, document);
      final gesture = await tester.startGesture(const Offset(20, 20));
      await gesture.moveTo(const Offset(60, 40));
      await gesture.moveTo(const Offset(90, 40));
      await gesture.cancel();
      await tester.pump();

      expect(calls.strokes, isEmpty);
      expect(calls.draftEnds, 1);
    });
  });

  group('a pinch survivor', () {
    testWidgets('never erases', (tester) async {
      final calls = await _pump(tester, document, tool: CanvasTool.eraser);
      final first = await tester.startGesture(const Offset(20, 20), pointer: 1);
      final second = await tester.startGesture(
        const Offset(200, 200),
        pointer: 2,
      );
      await second.up();
      await first.moveBy(const Offset(40, 40));
      await first.up();
      await tester.pump();

      expect(calls.erased, isEmpty);
    });

    testWidgets('never starts a fresh stroke when a third finger lands', (
      tester,
    ) async {
      final calls = await _pump(tester, document);
      final first = await tester.startGesture(const Offset(20, 20), pointer: 1);
      final second = await tester.startGesture(
        const Offset(200, 200),
        pointer: 2,
      );
      await first.up();
      await second.moveBy(const Offset(40, 40));
      await second.moveBy(const Offset(40, 40));
      await second.up();
      await tester.pump();

      expect(calls.strokes, isEmpty);
    });
  });

  group('the board letterbox', () {
    testWidgets('a press that began outside it never draws on its edge', (
      tester,
    ) async {
      document
        ..setViewport(const Size(800, 600))
        ..setBoard(canvasBoard);
      final calls = await _pump(tester, document);
      final gesture = await tester.startGesture(const Offset(20, 20));
      await gesture.moveTo(const Offset(150, 150));
      await gesture.moveTo(const Offset(250, 250));
      await gesture.up();
      await tester.pump();

      expect(calls.strokes, isEmpty);
    });
  });

  group('mouse buttons', () {
    for (final tool in [CanvasTool.pen, CanvasTool.pan]) {
      testWidgets('a right-click with the ${tool.name} tool acts on nothing', (
        tester,
      ) async {
        final calls = await _pump(tester, document, tool: tool);
        final mouse = await tester.startGesture(
          const Offset(30, 30),
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await mouse.moveBy(const Offset(2, 1));
        await mouse.up();
        await tester.pump();

        expect(calls.strokes, isEmpty);
        expect(calls.selectStarts, 0);
        expect(calls.taps, isEmpty);
      });
    }

    testWidgets('a right-click beside a held primary press changes nothing', (
      tester,
    ) async {
      final calls = await _pump(tester, document);
      final left = await tester.startGesture(
        const Offset(30, 30),
        pointer: 1,
        kind: PointerDeviceKind.mouse,
      );
      final right = await tester.startGesture(
        const Offset(80, 80),
        pointer: 2,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await right.up();
      await left.moveTo(const Offset(70, 30));
      await left.up();
      await tester.pump();

      expect(calls.strokes, hasLength(1));
    });
  });

  group('a stylus', () {
    testWidgets('keeps drawing while a palm lands beside it', (tester) async {
      final calls = await _pump(tester, document);
      final pen = await tester.startGesture(
        const Offset(30, 30),
        pointer: 1,
        kind: PointerDeviceKind.stylus,
      );
      await pen.moveTo(const Offset(60, 30));
      final palm = await tester.startGesture(
        const Offset(300, 300),
        pointer: 2,
      );
      await pen.moveTo(const Offset(90, 30));
      await palm.moveBy(const Offset(10, 10));
      await palm.up();
      await pen.up();
      await tester.pump();

      expect(calls.strokes, hasLength(1));
      expect(calls.strokes.single.length, greaterThanOrEqualTo(3));
    });

    testWidgets('outranks a palm that was already resting', (tester) async {
      final calls = await _pump(tester, document);
      final palm = await tester.startGesture(
        const Offset(300, 300),
        pointer: 1,
      );
      final pen = await tester.startGesture(
        const Offset(30, 30),
        pointer: 2,
        kind: PointerDeviceKind.stylus,
      );
      await pen.moveTo(const Offset(60, 30));
      await pen.moveTo(const Offset(90, 30));
      await pen.up();
      await palm.up();
      await tester.pump();

      expect(calls.strokes, hasLength(1));
    });

    testWidgets('does not turn a palm into a pinch', (tester) async {
      await _pump(tester, document);
      final before = document.camera;
      final pen = await tester.startGesture(
        const Offset(30, 30),
        pointer: 1,
        kind: PointerDeviceKind.stylus,
      );
      final palm = await tester.startGesture(
        const Offset(300, 300),
        pointer: 2,
      );
      await palm.moveBy(const Offset(80, 80));
      await palm.up();
      await pen.up();
      await tester.pump();

      expect(document.camera, before);
    });

    testWidgets('its eraser end erases whatever tool is armed', (
      tester,
    ) async {
      final calls = await _pump(tester, document);
      final pen = await tester.startGesture(
        const Offset(30, 30),
        kind: PointerDeviceKind.invertedStylus,
      );
      await pen.moveTo(const Offset(60, 30));
      await pen.up();
      await tester.pump();

      expect(calls.erased, isNotEmpty);
      expect(calls.strokes, isEmpty);
      expect(calls.eraseEnds, 1);
    });
  });

  group('the gesture keeps what it began with', () {
    testWidgets('a tool change ends the old tool and starts nothing new', (
      tester,
    ) async {
      final tools = ValueNotifier(CanvasTool.pen);
      addTearDown(tools.dispose);
      final calls = await _pump(tester, document, tools: tools);
      final gesture = await tester.startGesture(const Offset(20, 20));
      await gesture.moveTo(const Offset(60, 40));
      await gesture.moveTo(const Offset(90, 40));
      tools.value = CanvasTool.eraser;
      await tester.pump();
      await gesture.moveTo(const Offset(120, 40));
      await gesture.up();
      await tester.pump();

      expect(calls.strokes, hasLength(1), reason: 'the stroke so far is kept');
      expect(calls.strokes.single.length, 3);
      expect(calls.erased, isEmpty, reason: 'the new tool owns no gesture');
      expect(calls.eraseEnds, 0);
    });

    testWidgets(
        'a camera moved by someone else freezes the stroke where it was', (
      tester,
    ) async {
      final calls = await _pump(tester, document);
      final gesture = await tester.startGesture(const Offset(20, 20));
      await gesture.moveTo(const Offset(60, 40));
      document.setCamera(const Camera(x: 400, y: 300, zoom: 1));
      await tester.pump();
      await gesture.moveTo(const Offset(100, 40));
      await gesture.up();
      await tester.pump();

      expect(calls.strokes, hasLength(1));
      final stroke = calls.strokes.single;
      expect(stroke.first, const Offset(20, 20));
      expect(
        stroke.last,
        const Offset(60, 40),
        reason: 'drawn under the old camera, so saved under it',
      );
    });

    testWidgets('a held press is not a tap when it is lifted', (tester) async {
      final calls = await _pump(tester, document, tool: CanvasTool.pan);
      final touch = TestPointer(1);
      await tester.sendEventToBinding(
        touch.down(const Offset(40, 40), timeStamp: Duration.zero),
      );
      await tester.sendEventToBinding(
        touch.up(timeStamp: const Duration(milliseconds: 700)),
      );
      await tester.pump();

      expect(calls.taps, isEmpty);
    });

    testWidgets('a quick press still is', (tester) async {
      final calls = await _pump(tester, document, tool: CanvasTool.pan);
      final touch = TestPointer(1);
      await tester.sendEventToBinding(
        touch.down(const Offset(40, 40), timeStamp: Duration.zero),
      );
      await tester.sendEventToBinding(
        touch.up(timeStamp: const Duration(milliseconds: 80)),
      );
      await tester.pump();

      expect(calls.taps, hasLength(1));
    });
  });

  test('the wheel may reach a board fit under the usual zoom floor', () {
    document
      ..setViewport(const Size(400, 225))
      ..setBoard(canvasBoard);

    expect(document.zoomFloor, closeTo(400 / 1920, 1e-9));
  });
}
