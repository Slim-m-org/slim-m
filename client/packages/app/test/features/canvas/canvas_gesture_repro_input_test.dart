// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Hand-written replays of what the gesture fuzz and its follow-up probes found
/// about input that blocks or distorts creative work: panning from a stroke, a
/// long erase drag, a scroll mid-stroke, a stylus with a resting palm, finger
/// reach on a wide window, and the note editor on a sideways phone.
///
/// Each asserts the behaviour a person would expect, so each fails until its
/// bug is fixed.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_note_editor.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_gesture_fuzz_rig.dart';
import 'canvas_gesture_repro_support.dart';

void main() {
  group('the pan tool', () {
    testWidgets('a one-finger drag that starts on a stroke pans the board', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final rig = await FuzzRig.start(tester, phone: true);
        final document = rig.document;
        document.setCamera(
          Camera(x: 300, y: 220, zoom: document.camera.zoom * 4),
        );
        await tester.pump();
        final at = onStroke(rig, 's1');
        final before = document.camera;
        final pointer = await down(tester, at);
        for (var i = 1; i <= 8; i++) {
          await move(tester, pointer, at + Offset(-10.0 * i, -8.0 * i));
        }
        await lift(tester, pointer);

        expect(
          document.camera,
          isNot(before),
          reason: 'the drag selected the stroke and did nothing else',
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('the eraser', () {
    testWidgets('one drag removes every stroke it crosses, however many', (
      tester,
    ) async {
      final dots = [
        for (var i = 0; i < 80; i++)
          {
            'id': 'd$i',
            'kind': 'stroke',
            'z_index': i + 1,
            'x': 100.0 + i * 20,
            'y': 500.0,
            'w': 6.0,
            'h': 6.0,
            'props': {
              'points': [0.0, 0.0, 6.0, 6.0],
              'width': 3.0,
              'color': 'annotation',
            },
            'author_id': 'me',
            'seq': i + 1,
            'created_at': 0,
          },
      ];
      final rig = await FuzzRig.start(tester, phone: false, board: dots);
      await key(tester, LogicalKeyboardKey.keyE);
      final pointer = await down(
        tester,
        rig.toScreen(const Offset(95, 503)),
        kind: PointerDeviceKind.mouse,
      );
      for (var x = 95.0; x < 1750; x += 8) {
        await move(tester, pointer, rig.toScreen(Offset(x, 503)));
      }
      await lift(tester, pointer);

      final left = [
        for (var i = 0; i < 80; i++)
          if (rig.document.isAlive('d$i')) i,
      ];
      expect(
        left,
        isEmpty,
        reason: '${left.length} strokes the drag crossed are still there',
      );
    });
  });

  group('a pen stroke in progress', () {
    testWidgets('keeps its place on the board when the view scrolls under it', (
      tester,
    ) async {
      final rig = await FuzzRig.start(tester, phone: false);
      final document = rig.document;
      document.setCamera(
        document.camera.copyWith(zoom: document.camera.zoom * 3),
      );
      await tester.pump();
      await key(tester, LogicalKeyboardKey.keyP);
      final camera = document.camera;
      final top = rig.surfaceRect.topLeft;
      final start = rig.surfaceRect.center + const Offset(-200, -40);
      final worldStart = Offset(
        camera.x + (start.dx - top.dx) / camera.zoom,
        camera.y + (start.dy - top.dy) / camera.zoom,
      );

      final pointer = await down(tester, start, kind: PointerDeviceKind.mouse);
      await move(tester, pointer, start + const Offset(60, 0));
      await tester.sendEventToBinding(
        PointerScrollEvent(
          viewId: tester.view.viewId,
          kind: PointerDeviceKind.mouse,
          device: 1,
          position: start + const Offset(60, 0),
          scrollDelta: const Offset(0, 240),
        ),
      );
      await tester.pump();
      await move(tester, pointer, start + const Offset(120, 0));
      await lift(tester, pointer);

      final body = rig.fixture.posted.single;
      final points = ((body['props'] as Map)['points'] as List).cast<num>();
      final committed = Offset(
        (body['x'] as num).toDouble() + points[0],
        (body['y'] as num).toDouble() + points[1],
      );
      expect(
        (committed - worldStart).distance,
        lessThan(1),
        reason:
            'the stroke began at $worldStart on the board and was saved at $committed',
      );
    });
  });

  group('a shape placement still in flight', () {
    testWidgets('does not take the tool back from the pen picked meanwhile', (
      tester,
    ) async {
      final rig = await FuzzRig.start(
        tester,
        phone: false,
        placeDelay: const Duration(milliseconds: 400),
      );
      await key(tester, LogicalKeyboardKey.keyS);
      final at = rig.boardOnScreen.center + const Offset(0, 150);
      final tap = await down(tester, at, kind: PointerDeviceKind.mouse, id: 40);
      await tester.sendEventToBinding(tap.up());
      await tester.pump(const Duration(milliseconds: 50));

      await key(tester, LogicalKeyboardKey.keyP);
      final start = at + const Offset(-200, 40);
      final pen = await down(
        tester,
        start,
        kind: PointerDeviceKind.mouse,
        id: 41,
      );
      await move(tester, pen, start + const Offset(40, 10));
      await tester.pump(const Duration(milliseconds: 500));
      final toolWhileDrawing = rig.tool;
      await move(tester, pen, start + const Offset(80, 20));
      await lift(tester, pen);

      expect(
        toolWhileDrawing,
        CanvasTool.pen,
        reason: 'the shape reply switched the tool mid-stroke',
      );
      expect(
        rig.fixture.posted.where((p) => p['kind'] == 'stroke'),
        isNotEmpty,
        reason: 'the stroke the person drew was dropped',
      );
    });
  });

  group('a stylus', () {
    testWidgets('draws while a palm rests on the screen', (tester) async {
      final rig = await FuzzRig.start(tester, phone: true);
      await key(tester, LogicalKeyboardKey.keyP);
      final palm = await down(
        tester,
        rig.boardOnScreen.bottomRight - const Offset(30, 20),
        id: 30,
      );
      final start = rig.boardOnScreen.center;
      final pen = await down(
        tester,
        start,
        kind: PointerDeviceKind.stylus,
        id: 31,
      );
      await move(tester, pen, start + const Offset(30, 10));
      await move(tester, pen, start + const Offset(60, 20));
      await lift(tester, pen);
      await lift(tester, palm);

      expect(rig.fixture.posted, isNotEmpty, reason: 'the stroke was dropped');
    });
  });

  group('a finger on a wide window', () {
    testWidgets(
      'control: reaches a thin stroke from 8 px away on a narrow window',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        try {
          final rig = await FuzzRig.start(tester, phone: true);
          final pointer = await down(
            tester,
            onStroke(rig, 's1') + const Offset(0, 8),
          );
          await lift(tester, pointer);

          expect(rig.document.selectedObjectId.value, 's1');
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets(
      'reaches a thin stroke from 8 px away, as it does on a narrow one',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        try {
          final rig = await FuzzRig.start(tester, phone: true);
          tester.view.physicalSize = const Size(844, 390);
          await tester.pump(const Duration(milliseconds: 100));
          final vertex = onStroke(rig, 's1');
          final pointer = await down(tester, vertex + const Offset(0, 8));
          await lift(tester, pointer);

          expect(
            rig.document.selectedObjectId.value,
            's1',
            reason: 'a finger missed by 8 px',
          );
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  });

  group('the note editor on a phone turned sideways', () {
    for (final keyboard in [0.0, 190.0]) {
      testWidgets('lays out with ${keyboard.round()} of keyboard', (
        tester,
      ) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        try {
          final rig = await FuzzRig.start(tester, phone: true);
          final at = centerOf(rig, 'n1');
          for (var i = 0; i < 3; i++) {
            final mouse = TestPointer(20 + i, PointerDeviceKind.mouse, 1);
            await tester.sendEventToBinding(mouse.down(at));
            await tester.sendEventToBinding(mouse.up());
            await tester.pump(const Duration(milliseconds: 60));
          }
          await tester.pump(const Duration(milliseconds: 300));
          expect(
            find.byType(CanvasNoteEditor),
            findsOneWidget,
            reason: 'the editor did not open',
          );

          final errors = <FlutterErrorDetails>[];
          final previous = FlutterError.onError;
          FlutterError.onError = errors.add;
          tester.view.physicalSize = const Size(844, 390);
          tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
          addTearDown(tester.view.resetViewInsets);
          await tester.pump(const Duration(milliseconds: 50));
          await tester.pump(const Duration(milliseconds: 500));
          FlutterError.onError = previous;

          expect(
            errors.map((e) => e.exceptionAsString().split('\n').first),
            isEmpty,
            reason: 'turning the phone sideways broke the note editor',
          );
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  });
}
