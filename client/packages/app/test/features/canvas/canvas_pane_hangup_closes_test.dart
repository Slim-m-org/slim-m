// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Hanging up from inside the canvas closes the canvas with the call.
///
/// The owner: "clicking hangup while in canvas leaves me here ... I have to
/// specifically click close canvas to return out, WHICH THEN puts me BACK
/// into the voice call". The second half is `VoiceScreen`'s auto-join
/// reading a remount past `VoiceState.rejoinGuardWindow` as an arrival, so
/// the fix is for the canvas to close in the same motion as the leave.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_fullscreen.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pane.dart';
import 'package:slimm_rtc/rtc.dart';

import 'canvas_pane_harness.dart';
import '../../support/fake_voice.dart';
import '../voice/voice_controller_harness.dart';

const _connected = VoiceState(
  channelId: 'c1',
  state: VoiceSessionState.connected,
);

void main() {
  Future<(FakeVoiceController, ProviderContainer)> pump(
    WidgetTester tester, {
    bool fullscreen = false,
  }) async {
    final fixture = CanvasPaneFixture();
    late FakeVoiceController controller;
    final container = fixture.container(
      extraOverrides: [
        voiceControllerProvider.overrideWith(
          (ref) => controller = FakeVoiceController(
            ref,
            initial: _connected,
            session: FakeSession(),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(canvasOpenProvider.notifier).state = 'c1';
    if (fullscreen) {
      container.read(canvasFullscreenProvider.notifier).state = 'c1';
    }
    await pumpCanvasPane(tester, container);
    return (controller, container);
  }

  testWidgets('leaving the call closes the canvas, fullscreen included', (
    tester,
  ) async {
    final (controller, container) = await pump(tester, fullscreen: true);
    expect(container.read(canvasOpenProvider), 'c1');

    controller.replace(
      VoiceState(justLeftChannelId: 'c1', justLeftAt: DateTime.now()),
    );
    await tester.pump();

    expect(container.read(canvasOpenProvider), isNull);
    expect(container.read(canvasFullscreenProvider), isNull);
  });

  testWidgets('a call ending somewhere else leaves this canvas alone', (
    tester,
  ) async {
    final (controller, container) = await pump(tester);

    controller.replace(
      const VoiceState(
        channelId: 'elsewhere',
        state: VoiceSessionState.connected,
      ),
    );
    await tester.pump();
    controller.replace(const VoiceState());
    await tester.pump();

    expect(container.read(canvasOpenProvider), 'c1');
  });
}
