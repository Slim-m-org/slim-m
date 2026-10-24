// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_fullscreen.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pane.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_tile_camera.dart';
import 'package:slimm_app/src/features/voice/providers/share_watch.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../voice/voice_controller_harness.dart';
import 'canvas_pane_harness.dart';

class _DrivenVoiceController extends VoiceController {
  _DrivenVoiceController(super.ref, VoiceState initial)
    : super(session: FakeSession()) {
    state = initial;
  }
}

const _shareKey = ValueKey('screen:user-ada');

VoiceParticipant _p({
  double level = 0,
  bool speaking = false,
  bool camera = false,
  bool deafened = false,
}) => VoiceParticipant(
  identity: 'u1',
  name: 'Riley',
  audioLevel: level,
  isSpeaking: speaking,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
  isCameraOn: camera,
  isDeafened: deafened,
);

Future<ProviderContainer> _pumpPaneWithShare(
  WidgetTester tester, {
  bool fullscreenFirst = false,
  bool board = false,
  Size size = const Size(1280, 800),
}) async {
  final fixture = CanvasPaneFixture();
  final container = fixture.container(
    extraOverrides: [
      voiceControllerProvider.overrideWith(
        (ref) => _DrivenVoiceController(
          ref,
          const VoiceState(
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
              ),
            ],
          ),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  addTearDown(fixture.events.close);
  container.read(canvasOpenProvider.notifier).state = 'c1';
  if (fullscreenFirst) {
    container.read(canvasFullscreenProvider.notifier).state = 'c1';
  }
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await pumpCanvasPane(tester, container, board: board, tool: null);
  await tester.pumpAndSettle();
  return container;
}

void main() {
  test('a speaking level change alone does not rebuild the canvas', () {
    expect(
      CanvasCallParticipants([_p(level: 0.1)]),
      CanvasCallParticipants([_p(level: 0.9)]),
    );
  });

  test('starting or stopping speech does not rebuild the canvas either', () {
    expect(
      CanvasCallParticipants([_p()]),
      CanvasCallParticipants([_p(speaking: true)]),
    );
  });

  test('anything the canvas draws still counts as a change', () {
    expect(
      CanvasCallParticipants([_p()]),
      isNot(CanvasCallParticipants([_p(camera: true)])),
    );
    expect(
      CanvasCallParticipants([_p()]),
      isNot(CanvasCallParticipants([_p(deafened: true)])),
    );
    expect(
      CanvasCallParticipants([_p()]),
      isNot(const CanvasCallParticipants([])),
    );
  });

  test('VoiceParticipant.copyWith keeps every untouched field', () {
    const original = VoiceParticipant(
      identity: 'u1',
      name: 'Riley',
      isSpeaking: true,
      isMuted: true,
      isLocal: false,
      isScreenSharing: true,
      isCameraOn: true,
      audioLevel: 0.75,
      isDeafened: true,
    );
    final hiddenShare = original.copyWith(isScreenSharing: false);
    expect(hiddenShare.isScreenSharing, isFalse);
    expect(hiddenShare.identity, 'u1');
    expect(hiddenShare.name, 'Riley');
    expect(hiddenShare.isSpeaking, isTrue);
    expect(hiddenShare.isMuted, isTrue);
    expect(hiddenShare.isCameraOn, isTrue);
    expect(hiddenShare.audioLevel, 0.75);
    expect(hiddenShare.isDeafened, isTrue);
  });

  testWidgets('hiding a remote screen share removes its tile from the canvas', (
    tester,
  ) async {
    final container = await _pumpPaneWithShare(tester);
    expect(find.byKey(_shareKey), findsOneWidget);

    container.read(shareWatchProvider.notifier).stop('user-ada');
    await tester.pumpAndSettle();

    expect(find.byKey(_shareKey), findsNothing);
  });

  testWidgets(
    'double-clicking a presence tile expands it, Escape steps out of focus first when already fullscreen, and Exit fullscreen leaves in one click',
    (tester) async {
      final container = await _pumpPaneWithShare(tester, fullscreenFirst: true);
      expect(container.read(canvasFullscreenProvider), 'c1');
      expect(container.read(canvasFocusedTileProvider), isNull);

      final tileCenter = tester.getCenter(find.byKey(_shareKey));
      await tester.tapAt(tileCenter);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(tileCenter);
      await tester.pumpAndSettle();

      expect(container.read(canvasFocusedTileProvider), (
        channelId: 'c1',
        tileKey: 'screen:user-ada',
      ));

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(
        container.read(canvasFocusedTileProvider),
        isNull,
        reason: 'Escape unfocuses the tile first',
      );
      expect(
        container.read(canvasFullscreenProvider),
        'c1',
        reason: 'the manually entered fullscreen stays until a second Escape',
      );

      // Re-expand the tile by double-click, then click Exit fullscreen: one click leaves both.
      await tester.tapAt(tester.getCenter(find.byKey(_shareKey)));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(tester.getCenter(find.byKey(_shareKey)));
      await tester.pumpAndSettle();
      expect(container.read(canvasFocusedTileProvider), isNotNull);

      await tester.tap(find.byTooltip('Show controls'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Exit fullscreen'));
      await tester.pumpAndSettle();

      expect(container.read(canvasFocusedTileProvider), isNull);
      expect(container.read(canvasFullscreenProvider), isNull);
    },
  );

  test(
    'TileCameraForwarder pinch, trackpad, and scale signals reach a board zoom floor below minZoom',
    () {
      final document = CanvasDocument()
        ..setBoard(canvasBoard, sharedArea: canvasSharedArea)
        ..setViewport(const Size(600, 400));
      addTearDown(document.dispose);
      final floor = document.zoomFloor;
      expect(floor, lessThan(minZoom));
      final forwarder = TileCameraForwarder(
        document: document,
        originOf: () => const Offset(50, 50),
      );

      forwarder.signal(
        const PointerScaleEvent(
          position: Offset(80, 80),
          kind: PointerDeviceKind.trackpad,
          scale: 0.01,
        ),
      );
      expect(document.camera.zoom, closeTo(floor, 1e-6));

      document.setCamera(document.camera.copyWith(zoom: 1));
      forwarder.trackpadStart(
        const PointerPanZoomStartEvent(position: Offset(80, 80)),
      );
      forwarder.trackpadUpdate(
        const PointerPanZoomUpdateEvent(position: Offset(80, 80), scale: 0.01),
      );
      expect(document.camera.zoom, closeTo(floor, 1e-6));

      document.setCamera(document.camera.copyWith(zoom: 1));
      forwarder.touchDown(
        const PointerDownEvent(
          pointer: 1,
          position: Offset(0, 0),
          kind: PointerDeviceKind.touch,
        ),
      );
      forwarder.touchDown(
        const PointerDownEvent(
          pointer: 2,
          position: Offset(200, 0),
          kind: PointerDeviceKind.touch,
        ),
      );
      forwarder.touchMove(
        const PointerMoveEvent(
          pointer: 2,
          position: Offset(2, 0),
          kind: PointerDeviceKind.touch,
        ),
      );
      expect(document.camera.zoom, closeTo(floor, 1e-6));
    },
  );
}
