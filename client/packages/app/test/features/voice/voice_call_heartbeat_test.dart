// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A terminated app must leave a voice call; a backgrounded one must not.
///
/// Nothing can run once the process is actually killed, so this controller
/// cannot detect its own termination directly. What it can do is keep
/// refreshing proof of life with the server for as long as it is genuinely
/// connected, on an interval independent of the app's foreground state, so a
/// heartbeat that stops arriving is what the server (`voice/heartbeat.rs`)
/// treats as gone rather than waiting on the SFU's own reconnect grace.
///
/// Driven through `fake_async` rather than real wall-clock delays: a real
/// `Timer.periodic` at a few milliseconds is schedulable flake on a loaded
/// runner, and fake time makes every assertion below exact rather than
/// merely probable.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final harness = VoiceHarness();

  tearDown(harness.dispose);

  const interval = Duration(seconds: 15);

  Iterable<http.Request> heartbeatsIn(List<http.Request> requests) =>
      requests.where(
        (r) => r.method == 'POST' && r.url.path.endsWith('/voice/heartbeat'),
      );

  Iterable<http.Request> forgetsIn(List<http.Request> requests) =>
      requests.where(
        (r) => r.method == 'DELETE' && r.url.path.endsWith('/voice/heartbeat'),
      );

  test('joining a call starts an immediate, then periodic, heartbeat', () {
    fakeAsync((async) {
      final requests = <http.Request>[];
      final session = FakeSession();
      final controller = harness.controllerWith(
        session,
        voiceApi(onRequest: requests.add),
        voiceHeartbeatInterval: interval,
      );

      unawaited(controller.join('channel-1'));
      async.flushMicrotasks();
      // Real room events drive this transition; the fake stands in for one.
      session.emitState(VoiceSessionState.connected);
      async.flushMicrotasks();
      expect(
        heartbeatsIn(requests),
        isNotEmpty,
        reason: 'the first beat must not wait out a whole interval',
      );

      final afterJoin = heartbeatsIn(requests).length;
      async.elapse(interval * 2);
      expect(heartbeatsIn(requests).length, greaterThan(afterJoin));
    });
  });

  test('leaving the call stops the heartbeat and tells the server', () {
    fakeAsync((async) {
      final requests = <http.Request>[];
      final session = FakeSession();
      final controller = harness.controllerWith(
        session,
        voiceApi(onRequest: requests.add),
        voiceHeartbeatInterval: interval,
      );

      unawaited(controller.join('channel-1'));
      async.flushMicrotasks();
      session.emitState(VoiceSessionState.connected);
      async.flushMicrotasks();
      unawaited(controller.leave());
      async.flushMicrotasks();

      expect(
        forgetsIn(requests),
        isNotEmpty,
        reason:
            'a clean leave must say so, or the server only finds out once '
            'the entry goes stale and evicts a participant already gone',
      );
      final afterLeave = heartbeatsIn(requests).length;

      async.elapse(interval * 2);
      expect(
        heartbeatsIn(requests).length,
        afterLeave,
        reason: 'a clean leave must not keep proving a call that ended',
      );
    });
  });

  test('a call the SFU drops stops the heartbeat', () {
    fakeAsync((async) {
      final requests = <http.Request>[];
      final session = FakeSession();
      final controller = harness.controllerWith(
        session,
        voiceApi(onRequest: requests.add),
        voiceHeartbeatInterval: interval,
      );

      unawaited(controller.join('channel-1'));
      async.flushMicrotasks();
      session.emitState(VoiceSessionState.connected);
      async.flushMicrotasks();
      session.dropWith(VoiceDisconnect.removed);
      async.flushMicrotasks();
      final afterDrop = heartbeatsIn(requests).length;

      async.elapse(interval * 2);
      expect(heartbeatsIn(requests).length, afterDrop);
    });
  });

  test('backgrounding the app does not pause the call heartbeat', () {
    fakeAsync((async) {
      addTearDown(
        () => TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.paused,
      );

      final requests = <http.Request>[];
      final session = FakeSession();
      final controller = harness.controllerWith(
        session,
        voiceApi(onRequest: requests.add),
        voiceHeartbeatInterval: interval,
      );

      unawaited(controller.join('channel-1'));
      async.flushMicrotasks();
      session.emitState(VoiceSessionState.connected);
      async.flushMicrotasks();
      async.elapse(interval * 2);

      expect(
        heartbeatsIn(requests).length,
        3,
        reason:
            'a real background call must keep proving it is alive: one '
            'immediate beat plus two periodic ticks over two full intervals',
      );
    });
  });
}
