// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A call that comes back tells the others again that this client is deafened:
/// the mark lived on the participant the lost connection had.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

class _RejoiningSession extends FakeSession {
  @override
  Future<void> join({
    required String url,
    required String token,
    bool microphoneEnabled = true,
    bool cameraEnabled = false,
    bool canPublish = true,
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

class _RestartingSession extends FakeSession {
  final restarts = StreamController<void>.broadcast();

  @override
  Stream<void> get transportRestarts => restarts.stream;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final harness = VoiceHarness();

  tearDown(harness.dispose);

  const delays = [Duration(seconds: 2)];

  test('a deafened call says so again once the rejoin connects', () {
    fakeAsync((async) {
      final told = <String>[];
      final session = _RejoiningSession();
      final controller = harness.controllerWith(
        session,
        voiceApi(
          onRequest: (request) {
            if (request.url.path.endsWith('/voice/deafened')) {
              told.add(request.body);
            }
          },
        ),
        autoRejoinDelays: delays,
      );

      unawaited(controller.join('channel-1'));
      async.flushMicrotasks();
      unawaited(controller.toggleDeafen());
      async.flushMicrotasks();
      expect(told, hasLength(1));

      session.dropWith(VoiceDisconnect.connectionLost);
      async.flushMicrotasks();
      async.elapse(delays.first);
      async.flushMicrotasks();

      expect(controller.state.state, VoiceSessionState.connected);
      expect(controller.state.deafened, isTrue);
      expect(told, hasLength(2));
      expect(told.last, contains('true'));
    });
  });

  test('a call that was never deafened says nothing when it comes back', () {
    fakeAsync((async) {
      final told = <String>[];
      final session = _RejoiningSession();
      final controller = harness.controllerWith(
        session,
        voiceApi(
          onRequest: (request) {
            if (request.url.path.endsWith('/voice/deafened')) {
              told.add(request.body);
            }
          },
        ),
        autoRejoinDelays: delays,
      );

      unawaited(controller.join('channel-1'));
      async.flushMicrotasks();
      session.dropWith(VoiceDisconnect.connectionLost);
      async.flushMicrotasks();
      async.elapse(delays.first);
      async.flushMicrotasks();

      expect(controller.state.state, VoiceSessionState.connected);
      expect(told, isEmpty);
    });
  });

  test(
    'a deafened call says so again after livekit restarts its connection',
    () {
      fakeAsync((async) {
        final told = <String>[];
        final session = _RestartingSession();
        final controller = harness.controllerWith(
          session,
          voiceApi(
            onRequest: (request) {
              if (request.url.path.endsWith('/voice/deafened')) {
                told.add(request.body);
              }
            },
          ),
        );

        unawaited(controller.join('channel-1'));
        async.flushMicrotasks();
        unawaited(controller.toggleDeafen());
        async.flushMicrotasks();
        expect(told, hasLength(1));

        session.restarts.add(null);
        async.flushMicrotasks();

        expect(
          told,
          hasLength(2),
          reason: 'the restart rejoined as a participant with no mark',
        );
        expect(told.last, contains('true'));
      });
    },
  );

  test('a restart says nothing for a call that was never deafened', () {
    fakeAsync((async) {
      final told = <String>[];
      final session = _RestartingSession();
      harness.controllerWith(
        session,
        voiceApi(
          onRequest: (request) {
            if (request.url.path.endsWith('/voice/deafened')) {
              told.add(request.body);
            }
          },
        ),
      );

      session.restarts.add(null);
      async.flushMicrotasks();

      expect(told, isEmpty);
    });
  });
}
