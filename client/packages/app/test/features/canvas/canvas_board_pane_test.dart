// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas pane as the shared board: it opens fitted on the pan tool, a
/// pen stroke keeps its thickness on the drawer's screen at any zoom, and
/// following ends when the follower moves.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/members/widgets/member_pane.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_engine.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_pane_harness.dart';

void main() {
  testWidgets('opens on the pan tool with the whole board fitted', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);

    await pumpCanvasPane(tester, container, board: true, tool: null);

    final document = surfaceDocument(tester);
    expect(document.isFitted, isTrue);
    expect(
      document.worldView.inflate(1e-6).contains(canvasBoard.topLeft),
      isTrue,
    );
    expect(
      document.worldView.inflate(1e-6).contains(canvasBoard.bottomRight),
      isTrue,
    );
    final surface = tester.widget<CanvasSurface>(find.byType(CanvasSurface));
    expect(surface.tool, CanvasTool.pan);
  });

  testWidgets('the same stroke keeps its screen thickness at any zoom', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);

    final widths = <double>[];
    for (final zoom in [1.0, 2.0]) {
      surfaceDocument(tester).setCamera(Camera(zoom: zoom));
      await tester.pump();
      final gesture = await tester.startGesture(const Offset(100, 100));
      await gesture.moveTo(const Offset(160, 140));
      await gesture.up();
      await tester.pumpAndSettle();
      widths.add((fixture.posted.last['props'] as Map)['width'] as double);
    }

    // Medium is 3 screen px: 3 world units at 1x, 1.5 at 2x.
    expect(widths, [3.0, 1.5]);
    expect(widths[0] * 1.0, widths[1] * 2.0, reason: 'same size on screen');
  });

  testWidgets(
    'following stops when the follower pans, not when the window moves',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final fixture = CanvasPaneFixture();
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);
      await pumpCanvasPane(tester, container, board: true, tool: null);
      final relay = container
          .read(canvasEngineProvider('c1').notifier)
          .viewRelay;
      final document = surfaceDocument(tester);

      relay.applyRemote(
        'amy',
        const Rect.fromLTWH(960, 540, 480, 270),
        summon: false,
      );
      relay.follow('amy');
      await tester.pump();
      expect(document.isFitted, isFalse);
      expect(relay.following.value, 'amy');

      tester.view.physicalSize = const Size(1000, 800);
      await tester.pump();
      expect(relay.following.value, 'amy', reason: 'a resize only refits');

      document.setCamera(document.camera.copyWith(x: document.camera.x - 20));
      await tester.pump();
      expect(relay.following.value, isNull, reason: 'the follower moved');
    },
  );

  testWidgets('choosing the personal view stops following', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container, board: true, tool: null);
    final engine = container.read(canvasEngineProvider('c1').notifier);
    engine.viewRelay.follow('amy');

    engine.viewMode.showPersonal();

    expect(engine.viewRelay.following.value, isNull);
  });

  testWidgets('a person on the canvas can be followed and unfollowed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container, board: true, tool: null);
    final engine = container.read(canvasEngineProvider('c1').notifier);
    engine.cursors.upsert(
      id: 'u2',
      x: 500,
      y: 300,
      label: 'Amy',
      colorIndex: 0,
    );
    await tester.pump();

    expect(find.bySemanticsLabel('Bring everyone to me'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Follow Amy'));
    await tester.pump();
    expect(engine.viewRelay.following.value, 'u2');

    await tester.tap(find.bySemanticsLabel('Stop following Amy'));
    await tester.pump();
    expect(engine.viewRelay.following.value, isNull);
  });

  testWidgets('a screen reader can follow and unfollow, by the semantic tap', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container, board: true, tool: null);
    final engine = container.read(canvasEngineProvider('c1').notifier);
    engine.cursors.upsert(
      id: 'u2',
      x: 500,
      y: 300,
      label: 'Amy',
      colorIndex: 0,
    );
    await tester.pump();

    tester.semantics.tap(find.semantics.byLabel('Follow Amy'));
    await tester.pump();
    expect(engine.viewRelay.following.value, 'u2');

    tester.semantics.tap(find.semantics.byLabel('Following Amy, tap to stop'));
    await tester.pump();
    expect(engine.viewRelay.following.value, isNull);
    handle.dispose();
  });

  testWidgets('tapping a cursor on the canvas follows its owner', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container, board: true, tool: null);
    final engine = container.read(canvasEngineProvider('c1').notifier);
    final document = surfaceDocument(tester);
    engine.cursors.upsert(
      id: 'u2',
      x: 960,
      y: 540,
      label: 'Amy',
      colorIndex: 0,
    );
    await tester.pump();

    final camera = document.camera;
    final at =
        tester.getTopLeft(find.byType(CanvasSurface)) +
        Offset((960 - camera.x) * camera.zoom, (540 - camera.y) * camera.zoom);
    final press = await tester.startGesture(at);
    await press.up();
    await tester.pump();

    expect(engine.viewRelay.following.value, 'u2');
  });

  for (final (size, docked) in [
    (const Size(1280, 800), true),
    (const Size(390, 844), false),
  ]) {
    testWidgets('Escape ${docked ? 'closes' : 'leaves alone'} the member list '
        'at ${size.width.toInt()} wide', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final fixture = CanvasPaneFixture();
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);
      await pumpCanvasPane(tester, container, board: true, tool: null);
      expect(container.read(memberPaneVisibleProvider), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(container.read(memberPaneVisibleProvider), !docked);
    });
  }
}
