// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A camera filling the canvas pane is held enlarged, which `applyReceiveVideoQuality` lifts to the top layer under Balanced and Data saver.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/providers/canvas_focus_video_hold.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_fullscreen.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pane.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_rtc/rtc.dart';

import '../voice/fake_voice_session.dart';
import '../voice/voice_controller_harness.dart';
import 'canvas_pane_harness.dart';

const _cameraKey = 'camera:user-ada';

class _DrivenVoiceController extends VoiceController {
  _DrivenVoiceController(super.ref, VoiceState initial, FakeSession session)
    : super(session: session) {
    state = initial;
  }
}

const _ada = VoiceParticipant(
  identity: 'user-ada',
  name: 'Ada',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
  isCameraOn: true,
);

Future<({FakeSession session, ProviderContainer container})> _pump(
  WidgetTester tester,
) async {
  final session = FakeSession();
  final fixture = CanvasPaneFixture();
  final container = fixture.container(
    extraOverrides: [
      voiceControllerProvider.overrideWith(
        (ref) => _DrivenVoiceController(
          ref,
          const VoiceState(
            channelId: 'c1',
            state: VoiceSessionState.connected,
            participants: [_ada],
          ),
          session,
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  addTearDown(fixture.events.close);
  container.read(canvasOpenProvider.notifier).state = 'c1';
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await pumpCanvasPane(tester, container, tool: null);
  await _settle(tester);
  return (session: session, container: container);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

Future<void> _focusTheCamera(WidgetTester tester) async {
  final tile = find.byKey(const ValueKey(_cameraKey));
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  addTearDown(mouse.removePointer);
  await mouse.addPointer(location: tester.getCenter(tile));
  await tester.pump(const Duration(milliseconds: 200));
  await tester.tap(
    find.descendant(
      of: tile,
      matching: find.bySemanticsLabel('Show this tile full screen'),
    ),
  );
  await _settle(tester);
}

void main() {
  testWidgets('focusing a camera tile holds it enlarged and clearing the focus '
      'releases it', (tester) async {
    final (:session, :container) = await _pump(tester);
    expect(session.enlargedHolds, isEmpty);

    await _focusTheCamera(tester);
    expect(session.enlargedReleases, isEmpty);

    expect(session.enlargedHolds, [_cameraKey]);

    container.read(canvasFocusedTileProvider.notifier).state = null;
    await _settle(tester);

    expect(session.enlargedReleases, [_cameraKey]);
  });

  testWidgets('closing the pane while a tile is focused releases the hold', (
    tester,
  ) async {
    final (:session, container: _) = await _pump(tester);
    await _focusTheCamera(tester);
    expect(session.enlargedReleases, isEmpty);

    await tester.pumpWidget(const SizedBox());
    await _settle(tester);

    expect(session.enlargedReleases, [_cameraKey]);
  });

  group('CanvasFocusVideoHold', () {
    test('moving focus swaps the hold and never holds two', () {
      final live = <String>{};
      final hold = CanvasFocusVideoHold((key) {
        live.add(key);
        return () => live.remove(key);
      });

      hold.follow('camera:a');
      hold.follow('camera:a');
      expect(live, {'camera:a'});
      hold.follow('screen:b');
      expect(live, {'screen:b'});
      hold.release();
      expect(live, isEmpty);
      expect(hold.heldKey, isNull);
    });
  });
}
