// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Full screen on a tile changes the view, never the tile (decision 0081): the camera fits the tile's world rect, ink lands in world coordinates over the share, and leaving restores the camera.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_fullscreen.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pane.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../voice/voice_controller_harness.dart';
import 'canvas_pane_harness.dart';

class _Voice extends VoiceController {
  _Voice(super.ref) : super(session: FakeSession()) {
    state = const VoiceState(
      channelId: 'c1',
      state: VoiceSessionState.connected,
      participants: [
        VoiceParticipant(
          identity: 'user-ada',
          name: 'Ada',
          isSpeaking: false,
          isMuted: false,
          isLocal: false,
          isScreenSharing: true,
          isCameraOn: false,
        ),
      ],
    );
  }
}

const _tileKey = 'screen:user-ada';
const _video = ValueKey('video:$_tileKey');

Future<({ProviderContainer container, CanvasPaneFixture fixture})> _pump(
  WidgetTester tester, {
  Size size = const Size(1280, 800),
}) async {
  final fixture = CanvasPaneFixture();
  final container = fixture.container(
    extraOverrides: [voiceControllerProvider.overrideWith((r) => _Voice(r))],
  );
  addTearDown(container.dispose);
  addTearDown(fixture.events.close);
  container.read(canvasOpenProvider.notifier).state = 'c1';
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await pumpCanvasPane(tester, container, board: true, tool: null);
  await tester.pumpAndSettle();
  return (container: container, fixture: fixture);
}

/// Zooms in on the share, as a viewer would, so its controls are clear of the corner chips.
Future<void> _zoomOntoShare(WidgetTester tester) async {
  final document = surfaceDocument(tester);
  final share = _worldRect(tester);
  const zoom = 1.2;
  document.setCamera(
    Camera(
      x: share.center.dx - document.viewport.width / (2 * zoom),
      y: share.center.dy - document.viewport.height / (2 * zoom),
      zoom: zoom,
    ),
  );
  await tester.pump();
}

Future<void> _enterFullscreen(WidgetTester tester) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  addTearDown(mouse.removePointer);
  await mouse.addPointer(location: tester.getCenter(find.byKey(_video)));
  await tester.pump(const Duration(milliseconds: 200));
  await tester.tap(find.bySemanticsLabel('Show this tile full screen'));
  await tester.pumpAndSettle();
}

/// The tile's rectangle in world units, read back from where it is painted.
Rect _worldRect(WidgetTester tester) {
  final camera = surfaceDocument(tester).camera;
  final origin = tester.getTopLeft(find.byType(CanvasSurface));
  final screen = tester.getRect(find.byKey(_video)).shift(-origin);
  return Rect.fromLTWH(
    screen.left / camera.zoom + camera.x,
    screen.top / camera.zoom + camera.y,
    screen.width / camera.zoom,
    screen.height / camera.zoom,
  );
}

void main() {
  testWidgets('full screen fits the camera to the tile and leaves the tile '
      'alone', (tester) async {
    await _pump(tester);
    await _zoomOntoShare(tester);
    final before = _worldRect(tester);

    await _enterFullscreen(tester);

    final surface = tester.getRect(find.byType(CanvasSurface));
    final shown = tester.getRect(find.byKey(_video));
    expect(_worldRect(tester).center.dx, closeTo(before.center.dx, 0.5));
    expect(_worldRect(tester).center.dy, closeTo(before.center.dy, 0.5));
    expect(_worldRect(tester).width, closeTo(before.width, 0.5));
    expect(_worldRect(tester).height, closeTo(before.height, 0.5));
    expect(shown.center.dx, closeTo(surface.center.dx, 1));
    final fillsWidth = (shown.width - surface.width).abs() < 1;
    final fillsHeight = (shown.height - surface.height).abs() < 1;
    expect(fillsWidth || fillsHeight, isTrue, reason: '$shown in $surface');
    expect(surface.contains(shown.topLeft), isTrue);
    expect(surface.inflate(1).contains(shown.bottomRight), isTrue);
  });

  testWidgets('a stroke drawn in full screen lands over the same part of the '
      'share', (tester) async {
    final (:container, :fixture) = await _pump(tester);
    await _zoomOntoShare(tester);
    await _enterFullscreen(tester);
    final share = _worldRect(tester);

    await tester.tap(find.byTooltip('Show controls'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Pen'));
    await tester.pump();
    final shown = tester.getRect(find.byKey(_video));
    expect(_worldRect(tester).center, share.center, reason: 'tile unchanged');
    final from = shown.center;
    final gesture = await tester.startGesture(
      from,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(from + const Offset(80, 40));
    await gesture.up();
    await tester.pumpAndSettle();

    final posted = fixture.posted.last;
    final camera = surfaceDocument(tester).camera;
    expect(
      (posted['x'] as num).toDouble(),
      closeTo(share.center.dx, 2 / camera.zoom),
    );
    expect(
      (posted['y'] as num).toDouble(),
      closeTo(share.center.dy, 2 / camera.zoom),
    );
    expect(container.read(canvasFullscreenProvider), 'c1');
  });

  testWidgets('leaving full screen restores the camera exactly', (
    tester,
  ) async {
    await _pump(tester);
    await _zoomOntoShare(tester);
    final before = surfaceDocument(tester).camera;

    await _enterFullscreen(tester);
    expect(surfaceDocument(tester).camera, isNot(before));
    await tester.tap(find.byTooltip('Show controls'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Exit fullscreen'));
    await tester.pumpAndSettle();

    expect(surfaceDocument(tester).camera, before);
  });

  testWidgets('a fitted board comes back fitted', (tester) async {
    final (:container, :fixture) = await _pump(tester);
    final document = surfaceDocument(tester);
    final before = document.camera;
    expect(document.isFitted, isTrue);

    container.read(canvasFocusedTileProvider.notifier).state = (
      channelId: 'c1',
      tileKey: _tileKey,
    );
    await tester.pumpAndSettle();
    expect(document.isFitted, isFalse);
    expect(document.camera.zoom, greaterThan(before.zoom));

    container.read(canvasFocusedTileProvider.notifier).state = null;
    await tester.pumpAndSettle();

    expect(document.camera, before);
    expect(document.isFitted, isTrue);
  });
}
