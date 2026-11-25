// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A Speak grant or revoke pushed to a call in progress reaches the controls without a rejoin.
library;

import 'package:flutter_test/flutter_test.dart';

import 'voice_controller_harness.dart';

void main() {
  late VoiceHarness harness;
  late FakeSession session;

  setUp(() {
    harness = VoiceHarness();
    session = FakeSession();
  });
  tearDown(() => harness.dispose());

  Future<dynamic> joined({required bool canPublish}) async {
    final controller = harness.controllerWith(
      session,
      voiceApi(canPublish: canPublish),
    );
    await controller.join('lounge');
    return controller;
  }

  test('a grant after a listen-only join lets the member speak', () async {
    final controller = await joined(canPublish: false);
    expect(controller.state.canPublish, isFalse);

    session.publishPermissions.add(true);
    await pumpEventQueue();

    expect(controller.state.canPublish, isTrue);
  });

  test('a revoke mid-call turns the microphone and camera off', () async {
    final controller = await joined(canPublish: true);
    expect(controller.state.canPublish, isTrue);

    session.publishPermissions.add(false);
    await pumpEventQueue();

    expect(controller.state.canPublish, isFalse);
    expect(controller.state.microphoneEnabled, isFalse);
    expect(controller.state.cameraEnabled, isFalse);
  });
}
