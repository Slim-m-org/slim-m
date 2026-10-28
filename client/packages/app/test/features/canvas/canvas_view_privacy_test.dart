// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Decision 0082 holds: nothing about a personal camera is relayed, so nobody
/// follows it and a summon never carries it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_engine.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../support/recording_sync.dart';
import 'canvas_pane_harness.dart';

void main() {
  setUp(RecordingSyncController.clear);

  testWidgets('a personal camera is never relayed, the shared one is', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fixture = CanvasPaneFixture();
    final container = fixture.container(
      extraOverrides: [
        syncControllerProvider.overrideWith(RecordingSyncController.new),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container, board: true, tool: null);
    await tester.pump(const Duration(milliseconds: 300));
    final engine = container.read(canvasEngineProvider('c1').notifier);
    final document = engine.document;

    final before = RecordingSyncController.views.length;
    document.setCamera(document.camera.copyWith(zoom: 3));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      RecordingSyncController.views.length,
      greaterThan(before),
      reason: 'the shared view is relayed so others can follow it',
    );

    final sharedLast = RecordingSyncController.views.last;
    engine.viewMode.showPersonal();
    await tester.pump(const Duration(milliseconds: 300));
    final inPersonal = RecordingSyncController.views.length;
    document.setCamera(document.camera.copyWith(zoom: 5, x: 40, y: 40));
    await tester.pump(const Duration(milliseconds: 300));
    document.setCamera(document.camera.copyWith(zoom: 6));
    await tester.pump(const Duration(seconds: 6));

    // The shared view's own repeat may still go out; a personal one never does.
    expect(
      RecordingSyncController.views.skip(inPersonal),
      everyElement(sharedLast),
      reason: 'a personal pan or zoom is private',
    );
  });

  testWidgets('Bring everyone to me is not offered from the personal view', (
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
    engine.cursors.upsert(id: 'amy', x: 1, y: 1, label: 'Amy', colorIndex: 0);
    await tester.pump();

    await tester.tap(find.byTooltip('People here'));
    await tester.pump();
    expect(find.text('Bring everyone to me'), findsOneWidget);

    engine.viewMode.showPersonal();
    await tester.pump();

    expect(find.text('Bring everyone to me'), findsNothing);
    expect(find.byTooltip('Follow Amy'), findsOneWidget);
  });
}
