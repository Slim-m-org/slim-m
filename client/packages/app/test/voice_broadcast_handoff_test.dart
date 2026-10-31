// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the iOS screen-share handoff.
///
/// The bug these pin: on iOS, asking to share only asks the system to offer a
/// broadcast picker. Nothing is published, and nobody sees a screen, until the
/// user starts the broadcast in it. Treating the request as success lights the
/// button over a share that is not happening, which is what the owner reported
/// as "it does nothing".
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

import 'features/voice/voice_controller_harness.dart';

void main() {
  final harness = VoiceHarness();

  tearDown(harness.dispose);

  test('a request awaiting a broadcast is not shown as sharing', () async {
    final session = FakeSession(
      screenShareOutcome: ScreenShareOutcome.pendingBroadcast,
    );
    final controller = harness.controllerWith(session, voiceApi());

    await controller.join('channel-1');
    await controller.share.setScreenShare(true);

    expect(controller.state.screenSharing, isFalse);
    expect(controller.state.awaitingBroadcast, isTrue);
    expect(controller.state.error, isNull);
  });

  test('a broadcast that never starts is reported, not left pending', () async {
    final session = FakeSession(
      screenShareOutcome: ScreenShareOutcome.pendingBroadcast,
    );
    final controller = harness.controllerWith(
      session,
      voiceApi(),
      broadcastStartTimeout: const Duration(milliseconds: 20),
    );

    await controller.join('channel-1');
    await controller.share.setScreenShare(true);
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(controller.state.awaitingBroadcast, isFalse);
    expect(controller.state.screenSharing, isFalse);
    expect(controller.state.error, contains('never started'));
  });

  test('the broadcast actually starting clears the wait', () async {
    final session = FakeSession(
      screenShareOutcome: ScreenShareOutcome.pendingBroadcast,
    );
    final controller = harness.controllerWith(
      session,
      voiceApi(),
      broadcastStartTimeout: const Duration(milliseconds: 20),
    );

    await controller.join('channel-1');
    await controller.share.setScreenShare(true);
    session.emitParticipants(const [
      VoiceParticipant(
        identity: 'user-1',
        name: 'me',
        isLocal: true,
        isSpeaking: false,
        isMuted: false,
        isScreenSharing: true,
      ),
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(controller.state.screenSharing, isTrue);
    expect(controller.state.awaitingBroadcast, isFalse);
    // The deadline must have been cancelled, not merely outrun: a live
    // share that reports a failure 30 seconds later is its own bug.
    expect(controller.state.error, isNull);
  });

  test('a build with no extension says so instead of waiting', () async {
    final session = FakeSession(
      screenShareOutcome: ScreenShareOutcome.unsupported,
    );
    final controller = harness.controllerWith(session, voiceApi());

    await controller.join('channel-1');
    await controller.share.setScreenShare(true);

    expect(controller.state.screenSharing, isFalse);
    expect(controller.state.awaitingBroadcast, isFalse);
    expect(controller.state.error, contains('extension'));
    expect(controller.state.retryable, isFalse);
  });
}
