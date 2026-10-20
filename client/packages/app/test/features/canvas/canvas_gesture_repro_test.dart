// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Hand-written replays of what the gesture fuzz found about gestures that are
/// cut short, redirected or ignored: a tool switch while a pointer is down, a
/// cancelled pointer, a right click, and two pointers at once.
///
/// Each asserts the behaviour a person would expect, so each fails until its
/// bug is fixed. They run on the fuzz rig: the real pane, a four-person call
/// and a seeded board of strokes, notes, shapes and an image.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart' show ValueKey;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_gesture_fuzz_rig.dart';
import 'canvas_gesture_repro_support.dart';

void main() {
  group('a tool switch while a pointer is down', () {
    testWidgets('does not leave a pen draft painted or its preview open', (
      tester,
    ) async {
      final rig = await FuzzRig.start(tester, phone: false);
      await key(tester, LogicalKeyboardKey.keyP);
      final start = rig.boardOnScreen.center + const Offset(0, 120);
      final pointer = await down(tester, start, kind: PointerDeviceKind.mouse);
      await move(tester, pointer, start + const Offset(30, 10));
      await move(tester, pointer, start + const Offset(60, 30));

      await key(tester, LogicalKeyboardKey.keyN);
      await lift(tester, pointer);

      expect(draftsEmpty(rig), isTrue, reason: 'the draft is still painted');
      final opened = rig.frames.strokePreviews.map((f) => f.id).toSet();
      final ended = rig.frames.strokePreviews
          .where((f) => f.ended)
          .map((f) => f.id)
          .toSet();
      expect(
        opened.difference(ended),
        isEmpty,
        reason: 'others keep seeing the stroke',
      );
    });

    testWidgets('still commits an erase that already removed an object', (
      tester,
    ) async {
      final rig = await FuzzRig.start(tester, phone: false);
      await key(tester, LogicalKeyboardKey.keyE);
      final at = onStroke(rig, 's1');
      final pointer = await down(tester, at);
      await move(tester, pointer, at + const Offset(4, 0));
      await move(tester, pointer, at + const Offset(8, 2));
      final hidden = !rig.document.isAlive('s1');

      await key(tester, LogicalKeyboardKey.keyP);
      await lift(tester, pointer);

      expect(hidden, isTrue, reason: 'the erase drag never reached the stroke');
      expect(
        removedIds(rig),
        contains('s1'),
        reason: 'hidden here, still on the server',
      );
    });

    testWidgets(
      'ends a drag instead of leaving the object lifted and uncommitted',
      (tester) async {
        final rig = await FuzzRig.start(tester, phone: false);
        final at = centerOf(rig, 'n1');
        final pointer = await down(tester, at);
        await move(tester, pointer, at + const Offset(40, 20));
        await move(tester, pointer, at + const Offset(80, 40));

        await key(tester, LogicalKeyboardKey.keyP);
        await lift(tester, pointer);

        expect(
          rig.document.elevatedObjectId.value,
          isNull,
          reason: 'n1 stays lifted',
        );
        final moved = rig.document.objectBounds('n1')!;
        expect(
          movedIds(rig).contains('n1') || (moved.x == 900 && moved.y == 300),
          isTrue,
          reason:
              'n1 moved here to (${moved.x.round()},${moved.y.round()}) and the server never heard',
        );
      },
    );
  });

  group('a cancelled pointer', () {
    testWidgets('sends no erase and leaves the stroke where it was', (
      tester,
    ) async {
      final rig = await FuzzRig.start(tester, phone: true);
      await key(tester, LogicalKeyboardKey.keyE);
      final at = onStroke(rig, 's1');
      final pointer = await down(tester, at);
      await move(tester, pointer, at + const Offset(3, 0));
      await move(tester, pointer, at + const Offset(6, 2));
      await tester.sendEventToBinding(pointer.cancel());
      await settle(tester);

      expect(
        removedIds(rig),
        isEmpty,
        reason: 'palm rejection erased a stroke',
      );
      expect(rig.document.isAlive('s1'), isTrue);
    });

    testWidgets('sends no move and puts the object back', (tester) async {
      final rig = await FuzzRig.start(tester, phone: true);
      final at = centerOf(rig, 'n1');
      final pointer = await down(tester, at);
      await move(tester, pointer, at + const Offset(20, 10));
      await move(tester, pointer, at + const Offset(40, 20));
      await tester.sendEventToBinding(pointer.cancel());
      await settle(tester);

      expect(movedIds(rig), isEmpty, reason: 'a cancelled drag moved a note');
      final b = rig.document.objectBounds('n1')!;
      expect((b.x, b.y), (900.0, 300.0));
    });
  });

  group('a press that is not a primary click', () {
    for (final tool in ['Shape', 'Note', 'Eraser']) {
      testWidgets('with the $tool tool only opens the menu', (tester) async {
        final rig = await FuzzRig.start(tester, phone: false);
        await key(tester, switch (tool) {
          'Shape' => LogicalKeyboardKey.keyS,
          'Note' => LogicalKeyboardKey.keyN,
          _ => LogicalKeyboardKey.keyE,
        });
        final over = tool == 'Eraser'
            ? onStroke(rig, 's1')
            : rig.boardOnScreen.center + const Offset(0, 200);
        final pointer = await down(
          tester,
          over,
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryButton,
        );
        await lift(tester, pointer);

        expect(
          rig.fixture.posted,
          isEmpty,
          reason: 'a right click placed something',
        );
        expect(
          removedIds(rig),
          isEmpty,
          reason: 'a right click erased something',
        );
        expect(
          rig.navigator.canPop() && tool == 'Note',
          isFalse,
          reason: 'a right click opened the note sheet',
        );
      });
    }
  });

  group('two pointers', () {
    testWidgets(
      'an erase still commits when another pointer is panning with the middle button',
      (tester) async {
        final rig = await FuzzRig.start(tester, phone: false);
        await key(tester, LogicalKeyboardKey.keyE);
        final at = onStroke(rig, 's1');
        final eraser = await down(tester, at, id: 8);
        await move(tester, eraser, at + const Offset(4, 0));
        await move(tester, eraser, at + const Offset(8, 2));
        final grab = await down(
          tester,
          rig.boardOnScreen.center + const Offset(0, 150),
          kind: PointerDeviceKind.mouse,
          buttons: kMiddleMouseButton,
          id: 9,
        );
        await lift(tester, eraser);
        await lift(tester, grab);

        expect(
          rig.document.isAlive('s1'),
          isFalse,
          reason: 'the erase drag never reached the stroke',
        );
        expect(
          removedIds(rig),
          contains('s1'),
          reason: 'hidden here, still on the server',
        );
      },
    );

    testWidgets(
      'a move still commits when a finger resting on a call tile outlives the drag',
      (tester) async {
        final rig = await FuzzRig.start(tester, phone: false);
        final at = centerOf(rig, 'n1');
        final dragger = await down(
          tester,
          at,
          kind: PointerDeviceKind.stylus,
          id: 10,
        );
        await move(tester, dragger, at + const Offset(40, 20));
        await move(tester, dragger, at + const Offset(80, 40));
        final tile = tester.getCenter(
          find.byKey(const ValueKey('camera:user-noor')),
        );
        final rest = await down(tester, tile, id: 11);
        await tester.sendEventToBinding(dragger.up());
        await tester.pump(const Duration(milliseconds: 50));
        await lift(tester, rest);

        expect(
          rig.document.elevatedObjectId.value,
          isNull,
          reason: 'n1 stays lifted',
        );
        expect(
          movedIds(rig),
          contains('n1'),
          reason: 'n1 moved here and the server never heard',
        );
      },
    );
  });
}
