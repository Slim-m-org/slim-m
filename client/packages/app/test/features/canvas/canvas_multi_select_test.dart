// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Picking several canvas objects with a drag box or a modifier click, then deleting or moving them as one.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_pane_harness.dart';

Future<CanvasPaneFixture> _pump(
  WidgetTester tester, {
  Set<String> locked = const {},
}) async {
  final fixture = CanvasPaneFixture()
    ..objects = [
      canvasNoteJson('n1', x: 300),
      canvasNoteJson('n2', x: 400),
      canvasNoteJson('n3', x: 600),
      canvasNoteJson('locked', x: 500),
    ]
    ..routes = (request) async {
      if (request.url.path.endsWith('/canvas/object-locks')) {
        return jsonResponse({'object_ids': locked.toList()});
      }
      return null;
    };
  final container = fixture.container();
  addTearDown(container.dispose);
  addTearDown(fixture.events.close);
  await pumpCanvasPane(tester, container, tool: 'Pan');
  await tester.pump();
  await tester.pump();
  return fixture;
}

Future<void> _drag(
  WidgetTester tester,
  Offset from,
  Offset to, {
  PointerDeviceKind kind = PointerDeviceKind.mouse,
  Duration hold = Duration.zero,
}) async {
  final gesture = await tester.startGesture(
    screenFor(tester, from),
    kind: kind,
  );
  await tester.pump(hold);
  await gesture.moveTo(screenFor(tester, to));
  await tester.pump();
  await gesture.moveTo(screenFor(tester, to + const Offset(1, 1)));
  await tester.pump();
  await gesture.up();
  await tester.pump();
}

Future<void> _click(
  WidgetTester tester,
  Offset world, {
  LogicalKeyboardKey? holding,
}) async {
  if (holding != null) await tester.sendKeyDownEvent(holding);
  final gesture = await tester.startGesture(
    screenFor(tester, world),
    kind: PointerDeviceKind.mouse,
  );
  await gesture.up();
  await tester.pump();
  if (holding != null) await tester.sendKeyUpEvent(holding);
}

Future<void> _key(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(key);
  await tester.sendKeyUpEvent(key);
  await tester.pump();
  await tester.pump();
}

Set<String> _picked(WidgetTester tester) =>
    surfaceDocument(tester).multiSelection.all;

Future<void> _rightClick(WidgetTester tester, Offset world) async {
  final gesture = await tester.startGesture(
    screenFor(tester, world),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await gesture.up();
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('Shift held while dragging a note keeps it on one axis', (
    tester,
  ) async {
    await _pump(tester);
    final document = surfaceDocument(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await _drag(tester, const Offset(410, 20), const Offset(470, 40));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

    expect(document.objectBounds('n2')!.y, 10);
    expect(document.objectBounds('n2')!.x, closeTo(460, 1.5));
  });

  testWidgets('the selection bar aligns the pick, one undo takes it back', (
    tester,
  ) async {
    final fixture = await _pump(tester);
    await _drag(tester, const Offset(290, 60), const Offset(430, 0));

    await tester.tap(find.bySemanticsLabel('Align'));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('Align right'));
    await tester.pump();
    await tester.pump();

    final moves = fixture.postedOps.where((op) => op['kind'] == 'move');
    expect(moves.map((op) => op['object_id']), ['n1']);
    expect(surfaceDocument(tester).objectBounds('n1')!.x, 400);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await _key(tester, LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(surfaceDocument(tester).objectBounds('n1')!.x, 300);
  });

  testWidgets(
    'right-clicking one of the pick offers align and delete for all',
    (tester) async {
      final fixture = await _pump(tester);
      await _drag(tester, const Offset(290, 60), const Offset(430, 0));

      await _rightClick(tester, const Offset(410, 20));
      expect(find.text('Distribute horizontally'), findsOneWidget);
      expect(_picked(tester), {'n1', 'n2'});
      await tester.tap(find.text('Align left'));
      await tester.pump();
      await tester.pump();

      expect(surfaceDocument(tester).objectBounds('n2')!.x, 300);
      expect(
        fixture.postedOps.where((op) => op['kind'] == 'move'),
        hasLength(1),
      );

      await _rightClick(tester, const Offset(310, 20));
      await tester.tap(find.text('Delete'));
      await tester.pump();
      await tester.pump();
      expect(fixture.deletedObjects, unorderedEquals(['n1', 'n2']));
    },
  );

  testWidgets('a mouse on a narrow window drags a box at once, not a pan', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pump(tester);

    await _drag(tester, const Offset(290, 60), const Offset(340, 0));

    expect(_picked(tester), {'n1'});
    expect(surfaceDocument(tester).camera.x, 0);
  });

  testWidgets('dragging a box over empty board picks the objects it touches', (
    tester,
  ) async {
    await _pump(tester);

    await _drag(tester, const Offset(290, 60), const Offset(430, 0));

    expect(_picked(tester), {'n1', 'n2'});
    expect(surfaceDocument(tester).selectedObjectId.value, isNull);
    expect(surfaceDocument(tester).multiSelection.marquee.value, isNull);
  });

  testWidgets('a drag box leaves a locked object out of the pick', (
    tester,
  ) async {
    await _pump(tester, locked: {'locked'});

    await _drag(tester, const Offset(290, 60), const Offset(530, 0));

    expect(_picked(tester), {'n1', 'n2'});
  });

  testWidgets('the box shows while the pointer is down', (tester) async {
    await _pump(tester);
    final gesture = await tester.startGesture(
      screenFor(tester, const Offset(290, 60)),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(screenFor(tester, const Offset(430, 0)));
    await tester.pump();

    expect(
      surfaceDocument(tester).multiSelection.marquee.value,
      const Rect.fromLTRB(290, 0, 430, 60),
    );
    await gesture.up();
  });

  testWidgets('Ctrl+click toggles an object into and out of the pick', (
    tester,
  ) async {
    await _pump(tester);

    await _click(tester, const Offset(310, 20));
    await _click(
      tester,
      const Offset(410, 20),
      holding: LogicalKeyboardKey.controlLeft,
    );
    expect(_picked(tester), {'n1', 'n2'});

    await _click(
      tester,
      const Offset(310, 20),
      holding: LogicalKeyboardKey.controlLeft,
    );
    expect(_picked(tester), {'n2'});
    expect(surfaceDocument(tester).selectedObjectId.value, 'n2');
  });

  testWidgets('Shift+click adds and never removes', (tester) async {
    await _pump(tester);

    await _click(tester, const Offset(310, 20));
    await _click(
      tester,
      const Offset(410, 20),
      holding: LogicalKeyboardKey.shiftLeft,
    );
    await _click(
      tester,
      const Offset(410, 20),
      holding: LogicalKeyboardKey.shiftLeft,
    );

    expect(_picked(tester), {'n1', 'n2'});
  });

  testWidgets('a modifier click does not pick a locked object', (tester) async {
    await _pump(tester, locked: {'locked'});

    await _click(tester, const Offset(310, 20));
    await _click(
      tester,
      const Offset(510, 20),
      holding: LogicalKeyboardKey.controlLeft,
    );

    expect(_picked(tester), {'n1'});
  });

  testWidgets(
    'Delete removes every picked object, and one undo brings them all back',
    (tester) async {
      final fixture = await _pump(tester);
      await _drag(tester, const Offset(290, 60), const Offset(430, 0));

      await _key(tester, LogicalKeyboardKey.delete);

      expect(fixture.deletedObjects, unorderedEquals(['n1', 'n2']));
      expect(surfaceDocument(tester).objectCount.value, 2);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await _key(tester, LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(fixture.posted, hasLength(2));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await _key(tester, LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(fixture.posted, hasLength(2));
    },
  );

  testWidgets('dragging a picked object moves the whole pick, as one undo', (
    tester,
  ) async {
    final fixture = await _pump(tester);
    await _drag(tester, const Offset(290, 60), const Offset(430, 0));
    final document = surfaceDocument(tester);

    await _drag(tester, const Offset(310, 20), const Offset(360, 70));

    final moves = fixture.postedOps.where((op) => op['kind'] == 'move');
    expect(moves.map((op) => op['object_id']), unorderedEquals(['n1', 'n2']));
    expect(document.objectBounds('n1')!.x, closeTo(350, 1.5));
    expect(document.objectBounds('n2')!.x, closeTo(450, 1.5));
    expect(document.objectBounds('n3')!.x, 600);
    expect(_picked(tester), {'n1', 'n2'});

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await _key(tester, LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(document.objectBounds('n1')!.x, 300);
    expect(document.objectBounds('n2')!.x, 400);
  });

  testWidgets('a plain click on one of the pick narrows it to that object', (
    tester,
  ) async {
    await _pump(tester);
    await _drag(tester, const Offset(290, 60), const Offset(430, 0));

    await _click(tester, const Offset(410, 20));

    expect(_picked(tester), {'n2'});
    expect(surfaceDocument(tester).selectedObjectId.value, 'n2');
  });

  testWidgets('Ctrl+A picks everything in view except what is locked', (
    tester,
  ) async {
    await _pump(tester, locked: {'locked'});

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await _key(tester, LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

    expect(_picked(tester), {'n1', 'n2', 'n3'});
  });

  testWidgets('Escape clears the pick', (tester) async {
    await _pump(tester);
    await _drag(tester, const Offset(290, 60), const Offset(430, 0));

    await _key(tester, LogicalKeyboardKey.escape);

    expect(_picked(tester), isEmpty);
  });

  testWidgets('a finger held on empty board then dragged draws the box', (
    tester,
  ) async {
    await _pump(tester);

    await _drag(
      tester,
      const Offset(290, 60),
      const Offset(430, 0),
      kind: PointerDeviceKind.touch,
      hold: const Duration(milliseconds: 700),
    );

    expect(_picked(tester), {'n1', 'n2'});
  });

  testWidgets('a finger dragged at once still pans and picks nothing', (
    tester,
  ) async {
    await _pump(tester);
    final before = surfaceDocument(tester).camera;

    await _drag(
      tester,
      const Offset(290, 60),
      const Offset(430, 0),
      kind: PointerDeviceKind.touch,
    );

    expect(_picked(tester), isEmpty);
    expect(surfaceDocument(tester).camera.x, isNot(before.x));
  });
}
