// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Owner report: with a busy board "I keep moving things" while panning on a phone.
/// A finger drag that starts on an unselected object pans; a selected one moves.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../support/async_wait.dart';
import 'canvas_pane_harness.dart';

const _onNote = Offset(20, 20);

Future<void> _drag(
  WidgetTester tester,
  CanvasDocument document,
  Offset world,
  PointerDeviceKind kind,
) async {
  final gesture = await tester.startGesture(
    _at(tester, document, world),
    kind: kind,
  );
  for (var i = 0; i < 6; i++) {
    await gesture.moveBy(const Offset(-20, -15));
    await tester.pump();
  }
  await gesture.up();
  await pumpFrames(tester);
}

Future<CanvasDocument> _open(WidgetTester tester) async {
  final fixture = CanvasPaneFixture()..objects = [canvasNoteJson('n')];
  final container = fixture.container();
  addTearDown(container.dispose);
  addTearDown(fixture.events.close);
  await pumpCanvasPane(tester, container, board: true, tool: null);
  await pumpFrames(tester);
  return surfaceDocument(tester);
}

Offset _at(WidgetTester tester, CanvasDocument document, Offset world) {
  final camera = document.camera;
  return screenFor(tester, Offset.zero) +
      Offset(
        (world.dx - camera.x) * camera.zoom,
        (world.dy - camera.y) * camera.zoom,
      );
}

void main() {
  testWidgets('a finger drag on an unselected object pans and moves nothing', (
    tester,
  ) async {
    final document = await _open(tester);
    final box = document.objectBounds('n')!;
    final camera = document.camera;

    await _drag(tester, document, _onNote, PointerDeviceKind.touch);

    expect(document.camera.x, isNot(camera.x));
    expect(document.objectBounds('n')!.x, box.x);
    expect(document.objectBounds('n')!.y, box.y);
  });

  testWidgets('a finger tap on an object selects it', (tester) async {
    final document = await _open(tester);

    final gesture = await tester.startGesture(_at(tester, document, _onNote));
    await gesture.up();
    await pumpFrames(tester);

    expect(document.selectedObjectId.value, 'n');
  });

  testWidgets('a finger drag on the selected object moves it', (tester) async {
    final document = await _open(tester);
    final tap = await tester.startGesture(_at(tester, document, _onNote));
    await tap.up();
    await pumpFrames(tester);
    final box = document.objectBounds('n')!;
    final camera = document.camera;

    await _drag(tester, document, _onNote, PointerDeviceKind.touch);

    expect(document.camera, camera);
    expect(document.objectBounds('n')!.x, lessThan(box.x));
  });

  testWidgets('a mouse drag on an unselected object still moves it', (
    tester,
  ) async {
    final document = await _open(tester);
    final box = document.objectBounds('n')!;
    final camera = document.camera;

    await _drag(tester, document, _onNote, PointerDeviceKind.mouse);

    expect(document.camera, camera);
    expect(document.objectBounds('n')!.x, lessThan(box.x));
  });
}
