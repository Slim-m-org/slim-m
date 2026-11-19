// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Leaving a call, when leaving is not instantaneous.
///
/// The room disconnect is a round trip to the SFU, and no hang-up control in
/// the app waits on it before becoming tappable again, so a rejoin can land
/// while the leave is still unwinding. That join waits for the leave: livekit's
/// cleanup of the old room stops the platform audio session, and the leave's
/// own resets (deafen, local mutes) must reach the next call, not be skipped.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_rtc/src/voice_call_flow.dart' show kJoinWaitsForLeave;
import 'support/no_audio_devices.dart';

/// A room that logs its connect, disconnect and dispose under [label];
/// [leaveGate] holds its disconnect and [disposeGate] its dispose.
class _TracedRoom extends lk.Room {
  _TracedRoom(this.label, this.log, {this.leaveGate, this.disposeGate});
  final String label;
  final List<String> log;
  final Future<void>? leaveGate;
  final Future<void>? disposeGate;

  @override
  Future<void> connect(
    String url,
    String token, {
    lk.ConnectOptions? connectOptions,
    lk.RoomOptions? roomOptions,
    lk.FastConnectOptions? fastConnectOptions,
  }) async =>
      log.add('$label connect');

  @override
  Future<void> disconnect() async {
    log.add('$label disconnect');
    await leaveGate;
    await super.disconnect();
  }

  @override
  Future<bool> dispose() async {
    log.add('$label dispose');
    await disposeGate;
    return super.dispose();
  }
}

/// The first call's disconnect waits on [gate]; every later room is quick.
VoiceSession _racedSession(Future<void> gate, List<String> log) {
  var built = 0;
  return VoiceSession(
    audioDevices: const NoAudioDevices(),
    roomFactory: () => ++built == 1
        ? _TracedRoom('old', log, leaveGate: gate)
        : _TracedRoom('new', log),
  );
}

/// A room that connects immediately and logs its own disconnect, so a test
/// can prove the disconnect was reached rather than skipped.
class _LoggingRoom extends lk.Room {
  _LoggingRoom(this.log);
  final List<String> log;

  @override
  Future<void> connect(
    String url,
    String token, {
    lk.ConnectOptions? connectOptions,
    lk.RoomOptions? roomOptions,
    lk.FastConnectOptions? fastConnectOptions,
  }) async {}

  @override
  Future<void> disconnect() async {
    log.add('disconnect');
    await super.disconnect();
  }
}

/// An iOS host that refuses to stop its broadcast, which used to abandon
/// every teardown step after it.
class _ThrowingBridge implements BroadcastBridge {
  @override
  bool get usesBroadcastExtension => true;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<void> requestStop() async => throw StateError('no broadcast host');

  @override
  set autoPublishEnabled(bool enabled) {}

  @override
  Stream<bool> get broadcastingChanges => const Stream.empty();
}

void main() {
  test(
      'a join that lands while a leave is still disconnecting connects once '
      'the old room is gone, and stays connected', () async {
    final gate = Completer<void>();
    final log = <String>[];
    final session = _racedSession(gate.future, log);
    addTearDown(session.dispose);

    await session.join(url: 'wss://a.invalid', token: 't1');
    expect(session.state, VoiceSessionState.connected);

    final leaving = session.leave();
    await pumpEventQueue();
    expect(log.last, 'old disconnect', reason: 'the teardown is in flight');

    final joining = session.join(url: 'wss://a.invalid', token: 't2');
    await pumpEventQueue();
    expect(log, isNot(contains('new connect')),
        reason: "the old room's cleanup stops the audio session a new one "
            'started, so the new one must not start under it');

    gate.complete();
    await leaving;
    await joining;
    await pumpEventQueue();

    expect(
        log, ['old connect', 'old disconnect', 'old dispose', 'new connect']);
    expect(session.state, VoiceSessionState.connected);
  });

  test('a rejoin that lands mid-leave starts the next call heard', () async {
    final gate = Completer<void>();
    final session = _racedSession(gate.future, []);
    addTearDown(session.dispose);
    await session.join(url: 'wss://a.invalid', token: 't1');
    expect(await session.setDeafened(true), isTrue);

    final leaving = session.leave();
    await pumpEventQueue();
    final joining = session.join(url: 'wss://a.invalid', token: 't2');
    await pumpEventQueue();
    gate.complete();
    await leaving;
    await joining;

    expect(session.state, VoiceSessionState.connected);
    expect(session.deafened, isFalse,
        reason: 'the app shows a call after a leave undeafened, so the '
            'session must not still be holding everyone silent');
  });

  test('a leave asked while a join waits on an earlier leave wins', () async {
    final gate = Completer<void>();
    final log = <String>[];
    final session = _racedSession(gate.future, log);
    addTearDown(session.dispose);
    await session.join(url: 'wss://a.invalid', token: 't1');

    final leaving = session.leave();
    await pumpEventQueue();
    final joining = session.join(url: 'wss://a.invalid', token: 't2');
    await pumpEventQueue();
    final leavingAgain = session.leave();
    gate.complete();
    await Future.wait([leaving, joining, leavingAgain]);

    expect(log, isNot(contains('new connect')));
    expect(session.state, VoiceSessionState.idle);
  });

  test('a leave that never finishes tearing down holds a join only so long',
      () {
    fakeAsync((async) {
      final log = <String>[];
      var built = 0;
      final session = VoiceSession(
        audioDevices: const NoAudioDevices(),
        roomFactory: () => ++built == 1
            ? _TracedRoom('old', log, disposeGate: Completer<void>().future)
            : _TracedRoom('new', log),
      );
      session.join(url: 'wss://a.invalid', token: 't1');
      async.flushMicrotasks();
      session.setDeafened(true);
      session.leave();
      async.flushMicrotasks();
      session.join(url: 'wss://a.invalid', token: 't2');
      async.elapse(kJoinWaitsForLeave - const Duration(milliseconds: 1));
      expect(log, isNot(contains('new connect')));

      async.elapse(const Duration(milliseconds: 2));
      expect(log.last, 'new connect');
      expect(session.state, VoiceSessionState.connected);
      expect(session.deafened, isFalse);
    });
  });

  test('a leave that is not superseded still reports idle', () async {
    final session = VoiceSession(
        audioDevices: const NoAudioDevices(),
        roomFactory: () => _LoggingRoom([]));
    addTearDown(session.dispose);

    await session.join(url: 'wss://a.invalid', token: 't');
    await session.leave();

    expect(session.state, VoiceSessionState.idle);
  });

  test(
      'a platform that refuses to stop its broadcast does not stop the room '
      'disconnecting', () async {
    final log = <String>[];
    final session = VoiceSession(
      audioDevices: const NoAudioDevices(),
      roomFactory: () => _LoggingRoom(log),
      broadcast: _ThrowingBridge(),
    );
    addTearDown(session.dispose);

    await session.join(url: 'wss://a.invalid', token: 't');
    await session.leave();

    expect(log, contains('disconnect'));
    expect(session.state, VoiceSessionState.idle);
  });
}
