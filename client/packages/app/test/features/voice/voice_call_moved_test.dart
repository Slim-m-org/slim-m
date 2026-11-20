// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A call the server ended because the account joined one on another device says so; the
/// server's word and the SFU's drop arrive in either order, and a plain removal keeps its text.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_move_follower.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

const _moved = 'Your call moved to another device.';
const _removed = "You're no longer in this call.";
const _delays = [Duration(seconds: 2), Duration(seconds: 5)];
const _heartbeat = Duration(seconds: 15);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final harness = VoiceHarness();
  late StreamController<api.ServerEvent> events;

  setUp(() => events = StreamController<api.ServerEvent>.broadcast());
  tearDown(() async {
    harness.dispose();
    await events.close();
  });

  ({VoiceController controller, FakeSession session}) inCall(
    FakeAsync async, {
    List<http.Request>? seen,
    bool failHeartbeat = false,
  }) {
    final epoch = DateTime(2026, 11, 19);
    final session = FakeSession();
    final controller = harness.controllerWith(
      session,
      voiceApi(failHeartbeat: failHeartbeat, onRequest: seen?.add),
      autoRejoinDelays: _delays,
      voiceHeartbeatInterval: _heartbeat,
      now: () => epoch.add(async.elapsed),
      extraOverrides: [liveEventsProvider.overrideWithValue(events.stream)],
    );
    harness.container.read(voiceMoveFollowerProvider);
    unawaited(controller.join('channel-1'));
    async.flushMicrotasks();
    session.emitState(VoiceSessionState.connected);
    async.flushMicrotasks();
    expect(controller.state.state, VoiceSessionState.connected);
    return (controller: controller, session: session);
  }

  void serverSaysMoved(FakeAsync async, String channelId) {
    events.add(
      api.VoiceRemoved(
        channelId: channelId,
        reason: api.VoiceRemovalReason.otherDevice,
      ),
    );
    async.flushMicrotasks();
  }

  test('the server saying so before the drop names the other device', () {
    fakeAsync((async) {
      final call = inCall(async);

      serverSaysMoved(async, 'channel-1');
      expect(call.controller.state.state, VoiceSessionState.connected);
      expect(call.controller.state.error, isNull);
      call.session.dropWith(VoiceDisconnect.removed);
      async.flushMicrotasks();

      expect(call.controller.state.state, VoiceSessionState.failed);
      expect(call.controller.state.error, _moved);
      expect(call.controller.state.rejoining, isFalse);
    });
  });

  test('the server saying so after the drop replaces the bare removal', () {
    fakeAsync((async) {
      final call = inCall(async);
      call.session.dropWith(VoiceDisconnect.removed);
      async.flushMicrotasks();
      expect(call.controller.state.error, _removed);

      serverSaysMoved(async, 'channel-1');

      expect(call.controller.state.error, _moved);
      expect(call.controller.state.rejoining, isFalse);
    });
  });

  test(
    'a drop read as the heartbeat sweep is not rejoined once the server says why',
    () {
      fakeAsync((async) {
        final seen = <http.Request>[];
        final call = inCall(async, seen: seen, failHeartbeat: true);
        async.elapse(_heartbeat * 2 + const Duration(seconds: 1));
        call.session.dropWith(VoiceDisconnect.removed);
        async.flushMicrotasks();
        expect(call.controller.state.rejoining, isTrue);

        serverSaysMoved(async, 'channel-1');
        async.elapse(_delays.reduce((a, b) => a + b) * 2);

        expect(call.controller.state.error, _moved);
        expect(call.controller.state.rejoining, isFalse);
        final tokens = seen.where((r) => r.url.path.endsWith('/voice/token'));
        expect(
          tokens,
          hasLength(1),
          reason: 'the comeback would take the call back',
        );
      });
    },
  );

  test('a plain removal still says only that the call is over', () {
    fakeAsync((async) {
      final call = inCall(async);

      serverSaysMoved(async, 'another-channel');
      call.session.dropWith(VoiceDisconnect.removed);
      async.flushMicrotasks();

      expect(call.controller.state.error, _removed);
    });
  });

  test('the next call here forgets the last one moved away', () {
    fakeAsync((async) {
      final call = inCall(async);
      serverSaysMoved(async, 'channel-1');
      call.session.dropWith(VoiceDisconnect.removed);
      async.flushMicrotasks();

      unawaited(call.controller.join('channel-1'));
      async.flushMicrotasks();
      call.session.emitState(VoiceSessionState.connected);
      async.flushMicrotasks();
      call.session.dropWith(VoiceDisconnect.removed);
      async.flushMicrotasks();

      expect(call.controller.state.error, _removed);
    });
  });
}
