// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call timer reads the call's age as the server reports it, so two
/// people in one call agree and a rejoin or reload does not restart it.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

import 'features/voice/voice_controller_harness.dart';

class _Session extends FakeSession {
  @override
  Future<void> join({
    required String url,
    required String token,
    bool microphoneEnabled = true,
    bool cameraEnabled = false,
  }) async {
    lastDisconnect = null;
    await super.join(
      url: url,
      token: token,
      microphoneEnabled: microphoneEnabled,
      cameraEnabled: cameraEnabled,
    );
    emitState(VoiceSessionState.connected);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final harness = VoiceHarness();
  tearDown(harness.dispose);
  final epoch = DateTime(2026, 10, 1, 12);

  test('joining a call that is a minute old starts the timer at a minute', () {
    fakeAsync((async) {
      final controller = harness.controllerWith(
        _Session(),
        voiceApi(callAgeMs: 61000),
        now: () => epoch.add(async.elapsed),
      );

      unawaited(controller.join('channel-1'));
      async.flushMicrotasks();

      final age = epoch.difference(controller.state.connectedAt!);
      expect(age, const Duration(seconds: 61));
    });
  });

  test(
    'a rejoin after a drop keeps the call, not this device, as the clock',
    () {
      fakeAsync((async) {
        final session = _Session();
        final controller = harness.controllerWith(
          session,
          voiceApi(),
          autoRejoinDelays: const [Duration(seconds: 2)],
          now: () => epoch.add(async.elapsed),
        );
        unawaited(controller.join('channel-1'));
        async.flushMicrotasks();
        final first = controller.state.connectedAt!;

        async.elapse(const Duration(seconds: 40));
        session.dropWith(VoiceDisconnect.connectionLost);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();

        expect(controller.state.state, VoiceSessionState.connected);
        expect(controller.state.connectedAt, first);
      });
    },
  );

  test('leaving and joining again is a new call with a new clock', () {
    fakeAsync((async) {
      final controller = harness.controllerWith(
        _Session(),
        voiceApi(),
        now: () => epoch.add(async.elapsed),
      );
      unawaited(controller.join('channel-1'));
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 30));
      unawaited(controller.leave());
      async.flushMicrotasks();
      unawaited(controller.join('channel-1'));
      async.flushMicrotasks();

      expect(
        controller.state.connectedAt,
        epoch.add(const Duration(seconds: 30)),
      );
    });
  });
}
