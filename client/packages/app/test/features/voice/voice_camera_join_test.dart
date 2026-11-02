// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A camera that opens after the call connects shows as pending, then settles.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

void main() {
  final harness = VoiceHarness();
  tearDown(harness.dispose);

  Future<(FakeSession, Future<void> Function())> connected() async {
    final session = FakeSession();
    final controller = harness.controllerWith(session, voiceApi());
    await controller.join('channel-1');
    session.emitState(VoiceSessionState.connected);
    return (session, () => controller.leave());
  }

  test('the camera button is pending while the join-time open runs', () async {
    final (session, _) = await connected();
    final controller = harness.container.read(voiceControllerProvider.notifier);

    session.cameraOpens.add(const CameraJoinOpen.started());
    await pumpEventQueue();
    expect(controller.state.cameraPending, isTrue);

    session.cameraOpens.add(const CameraJoinOpen.settled());
    await pumpEventQueue();
    expect(controller.state.cameraPending, isFalse);
    expect(controller.state.error, isNull);
  });

  test('a camera that fails to open leaves a persistent error', () async {
    final (session, _) = await connected();
    final controller = harness.container.read(voiceControllerProvider.notifier);

    session.cameraOpens.add(const CameraJoinOpen.started());
    session.cameraOpens.add(
      const CameraJoinOpen.settled(
        CameraFailure('boom', CameraFailureReason.permissionDenied),
      ),
    );
    await pumpEventQueue();

    expect(controller.state.cameraPending, isFalse);
    expect(controller.state.error, contains('denied'));
  });

  test('a timed out camera says it did not respond', () async {
    final (session, _) = await connected();
    final controller = harness.container.read(voiceControllerProvider.notifier);

    session.cameraOpens.add(const CameraJoinOpen.settled(CameraOpenTimedOut()));
    await pumpEventQueue();

    expect(controller.state.error, contains('did not respond'));
  });

  test('a toggle press is ignored while the join-time open runs', () async {
    final (session, _) = await connected();
    final controller = harness.container.read(voiceControllerProvider.notifier);

    session.cameraOpens.add(const CameraJoinOpen.started());
    await pumpEventQueue();
    await controller.toggleCamera();

    expect(session.cameraToggles, isEmpty);
  });
}
