// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The pane side of gesture ownership: a press on an object beats a nearby cursor, a first tap only selects, a late reply leaves the tool alone, the object menu offers Delete for images and notes, and touch holds open it.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_engine.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_fullscreen.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_pane_harness.dart';

CanvasTool _tool(WidgetTester tester) =>
    tester.widget<CanvasSurface>(find.byType(CanvasSurface)).tool;

Future<CanvasPaneFixture> _open(
  WidgetTester tester, {
  List<Map<String, dynamic>> objects = const [],
  String tool = 'Pen',
}) async {
  final fixture = CanvasPaneFixture()..objects = [...objects];
  final container = fixture.container();
  addTearDown(container.dispose);
  addTearDown(fixture.events.close);
  await pumpCanvasPane(tester, container, tool: tool);
  await tester.pumpAndSettle();
  return fixture;
}

void main() {
  testWidgets('a press on an object next to a cursor selects the object', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fixture = CanvasPaneFixture()
      ..objects = [canvasNoteJson('n', x: 940, authorId: 'me')];
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container, board: true, tool: null);
    await tester.pumpAndSettle();
    final engine = container.read(canvasEngineProvider('c1').notifier);
    final document = surfaceDocument(tester);
    engine.cursors.upsert(id: 'u2', x: 960, y: 25, label: 'Amy', colorIndex: 0);
    await tester.pump();

    final camera = document.camera;
    final at =
        tester.getTopLeft(find.byType(CanvasSurface)) +
        Offset((960 - camera.x) * camera.zoom, (25 - camera.y) * camera.zoom);
    final press = await tester.startGesture(at);
    await press.up();
    await tester.pump();

    expect(document.selectedObjectId.value, 'n');
    expect(engine.viewRelay.following.value, isNull);
  });

  testWidgets(
    'a late shape reply does not move the tool while a finger is down',
    (tester) async {
      final fixture = CanvasPaneFixture()..placeGate = Completer<void>();
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);
      await pumpCanvasPane(tester, container);
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel('Shape'));
      await tester.pump();
      final tap = await tester.startGesture(
        screenFor(tester, const Offset(50, 50)),
      );
      await tap.up();
      await tester.pump();

      final holding = await tester.startGesture(
        screenFor(tester, const Offset(300, 300)),
        pointer: 9,
      );
      fixture.placeGate!.complete();
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        _tool(tester),
        CanvasTool.shape,
        reason: 'the reply landed under a finger',
      );
      await holding.up();
      await tester.pumpAndSettle();
    },
  );

  testWidgets('a shape appears at once and a second tap waits for the first', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture()..placeGate = Completer<void>();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);
    await tester.pumpAndSettle();
    final document = surfaceDocument(tester);

    await tester.tap(find.bySemanticsLabel('Shape'));
    await tester.pump();
    final first = await tester.startGesture(
      screenFor(tester, const Offset(160, 160)),
    );
    await first.up();
    await tester.pump();
    expect(document.objectCount.value, 1, reason: 'shown before the reply');

    final second = await tester.startGesture(
      screenFor(tester, const Offset(400, 300)),
    );
    await second.up();
    await tester.pump();
    expect(fixture.posted, hasLength(1), reason: 'one at a time');

    fixture.placeGate!.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('a refused shape disappears again', (tester) async {
    final fixture = CanvasPaneFixture(placeStatus: 403);
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);
    await tester.pumpAndSettle();
    final document = surfaceDocument(tester);

    await tester.tap(find.bySemanticsLabel('Shape'));
    await tester.pump();
    final tap = await tester.startGesture(
      screenFor(tester, const Offset(160, 160)),
    );
    await tap.up();
    await tester.pumpAndSettle();

    expect(document.objectCount.value, 0);
  });

  group('the object menu', () {
    Future<void> rightClick(WidgetTester tester, Offset world) async {
      final mouse = await tester.startGesture(
        screenFor(tester, world),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await mouse.up();
      await tester.pumpAndSettle();
    }

    testWidgets('offers Delete for an image and leaves the tool alone', (
      tester,
    ) async {
      await _open(
        tester,
        objects: [canvasImageJson('i', x: 400, authorId: 'me')],
      );

      await rightClick(tester, const Offset(410, 20));

      expect(find.text('Delete'), findsOneWidget);
      expect(_tool(tester), CanvasTool.pen);
    });

    testWidgets('offers Delete for a note', (tester) async {
      await _open(
        tester,
        objects: [canvasNoteJson('n', x: 400, authorId: 'me')],
      );

      await rightClick(tester, const Offset(410, 20));

      expect(find.text('Delete'), findsOneWidget);
    });

    testWidgets("offers nothing on someone else's note without manage rights", (
      tester,
    ) async {
      await _open(
        tester,
        tool: 'Pan',
        objects: [canvasNoteJson('n', x: 400, authorId: 'other')],
      );

      await rightClick(tester, const Offset(410, 20));

      expect(find.text('Delete'), findsNothing);
      expect(find.text('Add note'), findsOneWidget);
    });

    testWidgets('Delete removes the note on the server', (tester) async {
      final fixture = await _open(
        tester,
        objects: [canvasNoteJson('n', x: 400, authorId: 'me')],
      );

      await rightClick(tester, const Offset(410, 20));
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(fixture.postedOps.single['kind'], 'remove');
      expect(fixture.postedOps.single['object_ids'], ['n']);
    });
  });

  group('a long press with a finger', () {
    testWidgets('opens the object menu with the Move tool', (tester) async {
      await _open(
        tester,
        objects: [canvasNoteJson('n', x: 400, authorId: 'me')],
        tool: 'Pan',
      );

      final hold = await tester.startGesture(
        screenFor(tester, const Offset(410, 20)),
      );
      await tester.pump(const Duration(milliseconds: 700));
      await hold.up();
      await tester.pumpAndSettle();

      expect(find.text('Delete'), findsOneWidget);
    });

    testWidgets('does not open the editor on release', (tester) async {
      await _open(
        tester,
        objects: [canvasNoteJson('n', x: 400, authorId: 'me')],
        tool: 'Pan',
      );

      final touch = TestPointer(4);
      await tester.sendEventToBinding(
        touch.down(screenFor(tester, const Offset(410, 20))),
      );
      await tester.pump(const Duration(milliseconds: 700));
      await tester.sendEventToBinding(
        touch.up(timeStamp: const Duration(milliseconds: 700)),
      );
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();

      expect(find.text('Save'), findsNothing);
    });

    testWidgets('is cancelled by a second finger', (tester) async {
      await _open(
        tester,
        objects: [canvasNoteJson('n', x: 400, authorId: 'me')],
        tool: 'Pan',
      );

      final first = await tester.startGesture(
        screenFor(tester, const Offset(410, 20)),
        pointer: 1,
      );
      await tester.pump(const Duration(milliseconds: 200));
      final second = await tester.startGesture(
        screenFor(tester, const Offset(300, 200)),
        pointer: 2,
      );
      await tester.pump(const Duration(milliseconds: 700));
      await first.up();
      await second.up();
      await tester.pumpAndSettle();

      expect(find.text('Delete'), findsNothing);
    });
  });

  group('fullscreen', () {
    Future<ProviderContainer> enter(WidgetTester tester) async {
      final fixture = CanvasPaneFixture();
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);
      await pumpCanvasPane(tester, container);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('More canvas actions'));
      await tester.pump();
      await tester.tap(find.text('Enter fullscreen'));
      await tester.pumpAndSettle();
      expect(_tool(tester), CanvasTool.pan, reason: 'fullscreen disarms');
      return container;
    }

    testWidgets('a deliberately chosen Pan survives leaving it', (
      tester,
    ) async {
      final container = await enter(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(container.read(canvasFullscreenProvider), isNull);
      expect(_tool(tester), CanvasTool.pan);
    });

    testWidgets('the tool in use before comes back when none was chosen', (
      tester,
    ) async {
      final container = await enter(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(container.read(canvasFullscreenProvider), isNull);
      expect(_tool(tester), CanvasTool.pen);
    });
  });
}
