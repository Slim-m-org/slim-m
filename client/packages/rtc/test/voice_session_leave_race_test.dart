// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Leaving a call, when leaving is not instantaneous.
///
/// `_teardown` clears `_room` before it awaits anything, deliberately, so a
/// join racing a teardown can tell at once that it has been superseded. The
/// cost of that is the mirror case nothing covered: a join starting *during*
/// a teardown builds its room unobstructed, and then the leave that was
/// still unwinding resumes and reports the session idle over the top of it.
///
/// The room disconnect is what makes the window real rather than theoretical
/// - it is a round trip to the SFU, and no hang-up control in the app waits
/// on it before becoming tappable again.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';
import 'support/no_audio_devices.dart';

/// A room that connects immediately and whose `disconnect` blocks on [gate],
/// standing in for the SFU round trip a hang-up really waits on.
class _SlowLeaveRoom extends lk.Room {
  _SlowLeaveRoom(this.gate, this.log);
  final Future<void> gate;
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
    await gate;
    await super.disconnect();
  }
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
      'a join that lands while a leave is still disconnecting is not '
      'reported idle by it', () async {
    final gate = Completer<void>();
    final log = <String>[];
    var built = 0;
    final session = VoiceSession(
      audioDevices: const NoAudioDevices(),
      roomFactory: () {
        built++;
        // Only the first call's own disconnect is the slow one being raced.
        return built == 1
            ? _SlowLeaveRoom(gate.future, log)
            : _LoggingRoom(log);
      },
    );
    addTearDown(session.dispose);

    await session.join(url: 'wss://a.invalid', token: 't1');
    expect(session.state, VoiceSessionState.connected);

    final leaving = session.leave();
    await pumpEventQueue();
    expect(log, ['disconnect'], reason: 'the teardown is genuinely in flight');

    await session.join(url: 'wss://a.invalid', token: 't2');
    expect(session.state, VoiceSessionState.connected);

    gate.complete();
    await leaving;
    await pumpEventQueue();

    expect(
      session.state,
      VoiceSessionState.connected,
      reason: 'the superseded leave speaks for a call that is already over',
    );
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
