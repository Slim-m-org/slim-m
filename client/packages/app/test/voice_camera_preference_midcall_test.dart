// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/providers/voice_settings_controller.dart';

import 'voice_controller_harness.dart';

void main() {
  final harness = VoiceHarness();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(harness.dispose);

  test('changing camera-on-join mid-call does not repaint the live camera '
      'state, and the next camera tap asks for on', () async {
    final session = FakeSession();
    final controller = harness.controllerWith(session, voiceApi());
    await controller.join('channel-1');
    expect(controller.state.cameraEnabled, isFalse);

    await harness.container
        .read(voiceSettingsControllerProvider.notifier)
        .setCameraOnJoin(true);

    await controller.toggleCamera();
    expect(
      session.askedForCameraOnToggle,
      isTrue,
      reason: 'the first tap on an off camera must turn it on',
    );
  });

  test(
    'a camera-on-join change made mid-call applies to the next join',
    () async {
      final session = FakeSession();
      final controller = harness.controllerWith(session, voiceApi());
      await controller.join('channel-1');
      await harness.container
          .read(voiceSettingsControllerProvider.notifier)
          .setCameraOnJoin(true);
      expect(controller.state.cameraEnabled, isFalse);

      await controller.leave();

      expect(controller.state.cameraEnabled, isTrue);
    },
  );
}
