// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// C-106: zooming under a full screen tile must not slide the ink off the feed.
///
/// The focused feed is anchored to the pane while ink follows the camera, so
/// any camera change while focused puts a stroke over a different part of the
/// picture than the one the person was looking at.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_fullscreen.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pane.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_rtc/rtc.dart';

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

void main() {
  testWidgets('zooming while a tile is full screen leaves the camera at fit, '
      'so ink stays over the feed', (tester) async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container(
      extraOverrides: [
        voiceControllerProvider.overrideWith((ref) => _Voice(ref)),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    container.read(canvasOpenProvider.notifier).state = 'c1';
    container.read(canvasFocusedTileProvider.notifier).state = (
      channelId: 'c1',
      tileKey: 'screen:user-ada',
    );
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpCanvasPane(tester, container, tool: null, board: true);
    await tester.pumpAndSettle();

    final before = surfaceDocument(tester).camera;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(400, 300));
    await tester.sendEventToBinding(
      const PointerScaleEvent(
        position: Offset(400, 300),
        kind: PointerDeviceKind.mouse,
        scale: 2,
      ),
    );
    await tester.pumpAndSettle();

    expect(surfaceDocument(tester).camera.zoom, before.zoom);
  });
}
