// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A dropped call comes back when the websocket does, not when a timer says so.
///
/// The timer tail is 30 seconds, so a phone whose network returned at second
/// 31 of an outage otherwise sat on "reconnecting" with a working socket.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';
import 'support/fake_sync.dart';

class _CountingSession extends FakeSession {
  int joins = 0;
  bool connects = true;

  @override
  Future<void> join({
    required String url,
    required String token,
    bool microphoneEnabled = true,
    bool cameraEnabled = false,
  }) async {
    joins++;
    lastDisconnect = null;
    await super.join(
      url: url,
      token: token,
      microphoneEnabled: microphoneEnabled,
      cameraEnabled: cameraEnabled,
    );
    emitState(
      connects ? VoiceSessionState.connected : VoiceSessionState.failed,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final harness = VoiceHarness();
  tearDown(harness.dispose);

  const delays = [Duration(seconds: 30), Duration(seconds: 30)];

  ({
    VoiceController controller,
    _CountingSession session,
    NoopSyncController sync,
  })
  build() {
    final session = _CountingSession();
    final controller = harness.controllerWith(
      session,
      voiceApi(),
      autoRejoinDelays: delays,
      extraOverrides: [
        syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
      ],
    );
    final sync =
        harness.container.read(syncControllerProvider.notifier)
            as NoopSyncController;
    return (controller: controller, session: session, sync: sync);
  }

  void dropCall(FakeAsync async, _CountingSession session) {
    session.dropWith(VoiceDisconnect.connectionLost);
    async.flushMicrotasks();
  }

  test('the socket coming back rejoins before the timer tail', () {
    fakeAsync((async) {
      final t = build();
      t.sync.report(SyncStatus.live);
      unawaited(t.controller.join('channel-1'));
      async.flushMicrotasks();

      t.sync.report(SyncStatus.offline);
      dropCall(async, t.session);
      expect(t.session.joins, 1);

      async.elapse(const Duration(seconds: 3));
      t.sync.report(SyncStatus.connecting);
      t.sync.report(SyncStatus.live);
      async.flushMicrotasks();

      expect(t.session.joins, 2);
      expect(t.controller.state.state, VoiceSessionState.connected);
      expect(t.controller.state.rejoining, isFalse);
    });
  });

  test(
    'a reconnect while an attempt is in flight does not double the join',
    () {
      fakeAsync((async) {
        final t = build();
        unawaited(t.controller.join('channel-1'));
        async.flushMicrotasks();
        t.session.connects = false;
        dropCall(async, t.session);

        t.sync.report(SyncStatus.live);
        t.sync.report(SyncStatus.offline);
        t.sync.report(SyncStatus.live);
        async.flushMicrotasks();

        expect(t.session.joins, 2);
      });
    },
  );

  test('a failed early attempt falls back to the timer, not a tight retry', () {
    fakeAsync((async) {
      final t = build();
      unawaited(t.controller.join('channel-1'));
      async.flushMicrotasks();
      t.session.connects = false;
      dropCall(async, t.session);

      t.sync.report(SyncStatus.live);
      async.flushMicrotasks();
      expect(t.session.joins, 2);
      expect(t.controller.state.rejoining, isTrue);

      async.elapse(const Duration(seconds: 29));
      expect(t.session.joins, 2);
      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();
      expect(t.session.joins, 3);
    });
  });

  test('a socket coming back with no drop pending joins nothing', () {
    fakeAsync((async) {
      final t = build();
      unawaited(t.controller.join('channel-1'));
      async.flushMicrotasks();

      t.sync.report(SyncStatus.offline);
      t.sync.report(SyncStatus.live);
      async.flushMicrotasks();

      expect(t.session.joins, 1);
    });
  });
}
