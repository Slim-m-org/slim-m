// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Grab-to-pan: holding the middle mouse button and dragging moves the
/// camera regardless of the active tool, without disturbing whatever that
/// tool was mid-way through - see `_beginPan`/`_interruptForPan`'s own docs.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

void main() {
  testWidgets('a middle-button drag pans the camera', (tester) async {
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

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.down(const Offset(100, 100), buttons: kMiddleMouseButton),
    );
    await tester.sendEventToBinding(pointer.move(const Offset(60, 130)));
    await tester.sendEventToBinding(pointer.up());
    await tester.pump();

    expect(
      document.camera.x,
      40,
      reason: 'dragging left should move the camera the opposite way, '
          'so content follows the hand',
    );
    expect(document.camera.y, -30);
  });

  testWidgets('a middle-button drag never places ink for the active tool', (
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
          onStroke: (_) => strokes++,
          onErase: erased.add,
        ),
      ),
    );
    await tester.pump();

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(
      pointer.down(const Offset(20, 20), buttons: kMiddleMouseButton),
    );
    await tester.sendEventToBinding(pointer.move(const Offset(80, 80)));
    await tester.sendEventToBinding(pointer.up());
    await tester.pump();

    expect(strokes, 0);
    expect(erased, isEmpty);
  });

  testWidgets(
    'the grab button joining an in-progress pen draft cancels it and pans instead',
    (tester) async {
      final document = CanvasDocument();
      addTearDown(document.dispose);
      var strokes = 0;
      var draftEnded = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasSurface(
            document: document,
            ink: const Color(0xFFE86A5C),
            onStroke: (_) => strokes++,
            onDraftEnded: () => draftEnded++,
          ),
        ),
      );
      await tester.pump();

      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(
        pointer.down(const Offset(20, 20), buttons: kPrimaryButton),
      );
      await tester.sendEventToBinding(pointer.move(const Offset(40, 40)));
      expect(draftEnded, 0, reason: 'the pen draft is still under way');

      await tester.sendEventToBinding(
        pointer.move(
          const Offset(70, 60),
          buttons: kPrimaryButton | kMiddleMouseButton,
        ),
      );
      expect(
        draftEnded,
        1,
        reason: 'the grab button joining cancels the draft immediately',
      );

      await tester.sendEventToBinding(pointer.move(const Offset(100, 90)));
      await tester.sendEventToBinding(pointer.up());
      await tester.pump();

      expect(strokes, 0, reason: 'a cancelled draft never becomes a stroke');
      expect(draftEnded, 1, reason: 'only the cancellation fired it');
      expect(
        document.camera.x,
        lessThan(0),
        reason: 'the drag after the grab joined should still have panned',
      );
    },
  );

  testWidgets(
    'the grab button joining an in-progress erase drag flushes it through onEraseEnd',
    (tester) async {
      final document = CanvasDocument();
      addTearDown(document.dispose);
      final erased = <Offset>[];
      var ends = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasSurface(
            document: document,
            ink: const Color(0xFFE86A5C),
            tool: CanvasTool.eraser,
            onStroke: (_) {},
            onErase: erased.add,
            onEraseEnd: () => ends++,
          ),
        ),
      );
      await tester.pump();

      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(
        pointer.down(const Offset(20, 20), buttons: kPrimaryButton),
      );
      await tester.sendEventToBinding(pointer.move(const Offset(40, 40)));
      expect(ends, 0);

      await tester.sendEventToBinding(
        pointer.move(
          const Offset(70, 60),
          buttons: kPrimaryButton | kMiddleMouseButton,
        ),
      );

      expect(
        ends,
        1,
        reason: 'the grab joining flushes the drag as one removal',
      );
      expect(erased, [const Offset(20, 20), const Offset(40, 40)]);

      await tester.sendEventToBinding(pointer.up());
      await tester.pump();

      expect(
        ends,
        1,
        reason: 'the pointer finally lifting must not flush a second time',
      );
    },
  );

  testWidgets(
    'the grab button joining an in-progress select drag flushes it through onSelectEnd',
    (tester) async {
      final document = CanvasDocument();
      addTearDown(document.dispose);
      var ends = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasSurface(
            document: document,
            ink: const Color(0xFFE86A5C),
            tool: CanvasTool.pan,
            onStroke: (_) {},
            onSelectEnd: () => ends++,
          ),
        ),
      );
      await tester.pump();

      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(
        pointer.down(const Offset(20, 20), buttons: kPrimaryButton),
      );
      await tester.sendEventToBinding(pointer.move(const Offset(40, 40)));
      await tester.sendEventToBinding(
        pointer.move(
          const Offset(70, 60),
          buttons: kPrimaryButton | kMiddleMouseButton,
        ),
      );

      expect(ends, 1);

      await tester.sendEventToBinding(pointer.up());
      await tester.pump();

      expect(ends, 1, reason: 'no second onSelectEnd once the pan ends');
    },
  );

  testWidgets(
    'a disabled surface still pans with the grab button, the same as the wheel already does',
    (tester) async {
      final document = CanvasDocument();
      addTearDown(document.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasSurface(
            document: document,
            ink: const Color(0xFFE86A5C),
            enabled: false,
            onStroke: (_) {},
          ),
        ),
      );
      await tester.pump();

      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(
        pointer.down(const Offset(20, 20), buttons: kMiddleMouseButton),
      );
      await tester.sendEventToBinding(pointer.move(const Offset(60, 20)));
      await tester.sendEventToBinding(pointer.up());
      await tester.pump();

      expect(document.camera.x, -40);
    },
  );

  testWidgets(
    'an unrelated second pointer lifting mid-grab does not end someone else\'s pan',
    (tester) async {
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

      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      final touch = TestPointer(2, PointerDeviceKind.touch);
      await tester.sendEventToBinding(
        mouse.down(const Offset(100, 100), buttons: kMiddleMouseButton),
      );
      await tester.sendEventToBinding(mouse.move(const Offset(80, 100)));
      // A second, unrelated pointer touches down and lifts mid-grab.
      await tester.sendEventToBinding(touch.down(const Offset(10, 10)));
      await tester.sendEventToBinding(touch.up());
      // The mouse's own drag continues to count toward the pan afterward.
      await tester.sendEventToBinding(mouse.move(const Offset(60, 100)));
      await tester.sendEventToBinding(mouse.up());
      await tester.pump();

      expect(
        document.camera.x,
        40,
        reason: 'the touch pointer\'s own up must not have ended the grab '
            'the mouse was still holding',
      );
    },
  );

  testWidgets(
    'a second pointer\'s own grab-button down mid-drag must not steal an '
    'already-owned pan',
    (tester) async {
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

      final a = TestPointer(1, PointerDeviceKind.mouse);
      final b = TestPointer(2, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(
        a.down(const Offset(100, 100), buttons: kMiddleMouseButton),
      );
      await tester.sendEventToBinding(a.move(const Offset(80, 100)));
      // A second pointer's own grab attempt, down then straight up - never held alongside a, or the surface's own two-finger scale gesture would confound this.
      await tester.sendEventToBinding(
        b.down(const Offset(200, 200), buttons: kMiddleMouseButton),
      );
      await tester.sendEventToBinding(b.up());
      // Pointer a's own drag continues, and must still count toward the pan.
      await tester.sendEventToBinding(a.move(const Offset(60, 100)));
      await tester.sendEventToBinding(a.up());
      await tester.pump();

      expect(
        document.camera.x,
        40,
        reason: 'pointer b\'s own grab-button down must not have taken '
            'ownership of the pan pointer a already started',
      );
    },
  );

  testWidgets(
    'releasing only the grab button while another stays down resumes the tool, not a stuck pan',
    (tester) async {
      final document = CanvasDocument();
      addTearDown(document.dispose);
      var strokes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: CanvasSurface(
            document: document,
            ink: const Color(0xFFE86A5C),
            onStroke: (_) => strokes++,
          ),
        ),
      );
      await tester.pump();

      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(
        pointer.down(
          const Offset(20, 20),
          buttons: kPrimaryButton | kMiddleMouseButton,
        ),
      );
      await tester.sendEventToBinding(
        pointer.move(
          const Offset(50, 50),
          buttons: kPrimaryButton | kMiddleMouseButton,
        ),
      );
      // The grab button lets go, but the primary button is still held.
      await tester.sendEventToBinding(
        pointer.move(const Offset(50, 60), buttons: kPrimaryButton),
      );
      await tester.sendEventToBinding(
        pointer.move(const Offset(70, 90), buttons: kPrimaryButton),
      );
      await tester.sendEventToBinding(pointer.up());
      await tester.pump();

      expect(
        strokes,
        1,
        reason: 'the primary drag should resume drawing once the grab '
            'button alone is released, not stay stuck panning until the '
            'whole pointer lifts',
      );
    },
  );

  testWidgets(
    'the cursor shows grabbing while panning, and the prior tool cursor after',
    (tester) async {
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

      const pointerId = 1;
      final pointer = TestPointer(pointerId, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(const Offset(50, 50)));
      await tester.pump();
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(
          pointerId,
        ),
        SystemMouseCursors.precise,
        reason: 'the pen tool cursor before any grab starts',
      );

      await tester.sendEventToBinding(
        pointer.down(const Offset(50, 50), buttons: kMiddleMouseButton),
      );
      await tester.sendEventToBinding(pointer.move(const Offset(80, 80)));
      await tester.pump();
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(
          pointerId,
        ),
        SystemMouseCursors.grabbing,
      );

      await tester.sendEventToBinding(pointer.up());
      await tester.sendEventToBinding(pointer.hover(const Offset(80, 80)));
      await tester.pump();
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(
          pointerId,
        ),
        SystemMouseCursors.precise,
        reason: 'the tool cursor returns once the grab ends',
      );
    },
  );

  testWidgets('a second finger landing ends the select gesture the first began',
      (
    tester,
  ) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    var ends = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CanvasSurface(
          document: document,
          ink: const Color(0xFFE86A5C),
          tool: CanvasTool.pan,
          onStroke: (_) {},
          onSelectEnd: () => ends++,
        ),
      ),
    );
    await tester.pump();

    final first = TestPointer(1, PointerDeviceKind.touch);
    final second = TestPointer(2, PointerDeviceKind.touch);
    await tester.sendEventToBinding(first.down(const Offset(100, 100)));
    expect(ends, 0);
    await tester.sendEventToBinding(second.down(const Offset(200, 100)));

    expect(ends, 1,
        reason: 'a pan anchored before the pinch must not outlive it');
    await tester.sendEventToBinding(second.up());
    await tester.sendEventToBinding(first.up());
  });
}
