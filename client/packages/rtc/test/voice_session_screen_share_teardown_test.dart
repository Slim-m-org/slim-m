// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Screen-share teardown tests, split out of `voice_session_test.dart` for
/// the file budget once this group grew to cover every way a call can end.
///
/// A capture that outlives the call it started for is a privacy failure, not
/// a resource leak, which is why this group covers every path separately
/// rather than trusting one to stand in for the rest, and why more than one
/// test here asserts *order* rather than only "it happened somewhere".
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';
import 'support/no_audio_devices.dart';

/// A room that connects without an SFU behind it, and logs its own
/// `disconnect()` into [log] so a test can see when it ran relative to the
/// bridge's own stop request. Its `localParticipant` stays null, which is
/// exactly the shape iOS produces on a share request: the call returns
/// having published nothing.
class _EmptyRoom extends lk.Room {
  _EmptyRoom(this.log);
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
    log.add('room.disconnect');
    await super.disconnect();
  }
}

/// Stands in for the iOS host. The hand-off itself has its own dedicated
/// tests in `screen_share_control_test.dart`; this only needs enough of the
/// seam to prove `VoiceSession` reaches it on every teardown path, in order.
class _FakeBridge implements BroadcastBridge {
  _FakeBridge({List<String>? log}) : _log = log;

  final List<String>? _log;

  @override
  bool get usesBroadcastExtension => true;

  int stopRequests = 0;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<void> requestStop() async {
    stopRequests++;
    _log?.add('bridge.requestStop');
  }

  @override
  set autoPublishEnabled(bool enabled) {}

  @override
  Stream<bool> get broadcastingChanges => const Stream.empty();
}

/// A bridge whose `requestStop` does not resolve until [gate] completes, so
/// a test can tell an awaited call apart from a fired-and-forgotten one.
class _GatedBridge implements BroadcastBridge {
  _GatedBridge(this.gate);
  final Future<void> gate;

  @override
  bool get usesBroadcastExtension => true;

  int stopRequests = 0;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<void> requestStop() async {
    stopRequests++;
    await gate;
  }

  @override
  set autoPublishEnabled(bool enabled) {}

  @override
  Stream<bool> get broadcastingChanges => const Stream.empty();
}

void main() {
  group('screen share outcome', () {
    test('stopping also ends the platform broadcast', () async {
      // Dropping the track without this leaves the phone still recording.
      final bridge = _FakeBridge();
      final session = VoiceSession(
          audioDevices: const NoAudioDevices(),
          roomFactory: () => _EmptyRoom([]),
          broadcast: bridge);
      addTearDown(session.dispose);

      await session.join(url: 'wss://a.invalid', token: 't');
      expect(
        await session.setScreenShareEnabled(false),
        ScreenShareOutcome.stopped,
      );
      expect(bridge.stopRequests, 1);
    });

    test('hanging up without stopping the share first still ends it', () async {
      // Leaving a call is not the same button as stopping a share.
      final bridge = _FakeBridge();
      final session = VoiceSession(
          audioDevices: const NoAudioDevices(),
          roomFactory: () => _EmptyRoom([]),
          broadcast: bridge);
      addTearDown(session.dispose);

      await session.join(url: 'wss://a.invalid', token: 't');
      await session.setScreenShareEnabled(true);
      expect(bridge.stopRequests, 0);

      await session.leave();

      expect(bridge.stopRequests, 2,
          reason: 'a hang-up must not leave the phone still recording; the '
              'ordered call and the dispose() backstop both fire here');
    });

    test(
        'hanging up asks the platform to stop before the room disconnects, '
        'not after', () async {
      final log = <String>[];
      final bridge = _FakeBridge(log: log);
      final session = VoiceSession(
          audioDevices: const NoAudioDevices(),
          roomFactory: () => _EmptyRoom(log),
          broadcast: bridge);
      addTearDown(session.dispose);

      await session.join(url: 'wss://a.invalid', token: 't');
      await session.setScreenShareEnabled(true);

      await session.leave();

      expect(log.first, 'bridge.requestStop',
          reason: 'both things happening is not enough; stopping the '
              'capture must be the first thing that happens, strictly '
              'before the room disconnects');
      expect(log, contains('room.disconnect'));
    });

    test('being removed from the call also ends an active broadcast', () async {
      // The SFU dropping this client never runs through leave() at all.
      final bridge = _FakeBridge();
      late _EmptyRoom room;
      final session = VoiceSession(
        audioDevices: const NoAudioDevices(),
        roomFactory: () => room = _EmptyRoom([]),
        broadcast: bridge,
      );
      addTearDown(session.dispose);

      await session.join(url: 'wss://a.invalid', token: 't');
      await session.setScreenShareEnabled(true);
      expect(bridge.stopRequests, 0);

      // streamCtrl is the plain stream .listen() subscribes to under emit().
      room.events.streamCtrl.add(
        lk.RoomDisconnectedEvent(
          reason: lk.DisconnectReason.participantRemoved,
        ),
      );
      await pumpEventQueue();

      expect(bridge.stopRequests, 2,
          reason: 'being removed must not leave the phone still recording');
    });

    test(
        'being removed awaits the stop request rather than firing it into '
        'the background', () async {
      final gate = Completer<void>();
      final bridge = _GatedBridge(gate.future);
      late _EmptyRoom room;
      final session = VoiceSession(
        audioDevices: const NoAudioDevices(),
        roomFactory: () => room = _EmptyRoom([]),
        broadcast: bridge,
      );
      addTearDown(session.dispose);
      // Registered after session.dispose, so LIFO runs this first if a failed assertion above never reached gate.complete().
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });

      await session.join(url: 'wss://a.invalid', token: 't');
      await session.setScreenShareEnabled(true);

      room.events.streamCtrl.add(
        lk.RoomDisconnectedEvent(
          reason: lk.DisconnectReason.participantRemoved,
        ),
      );
      await pumpEventQueue();

      expect(bridge.stopRequests, 1,
          reason: 'the request must already be in flight');
      expect(session.state, isNot(VoiceSessionState.failed),
          reason: 'a fired-and-forgotten call would already have moved on '
              'to reporting the call as ended; an awaited one has not, '
              'because the gate has not resolved yet');

      gate.complete();
      await pumpEventQueue();

      expect(session.state, VoiceSessionState.failed);
    });

    test('a disconnect this client itself asked for reaches no extra stop',
        () async {
      // leave() cancels the listener first, so _onDisconnected must never also fire for this same call ending.
      final bridge = _FakeBridge();
      final session = VoiceSession(
          audioDevices: const NoAudioDevices(),
          roomFactory: () => _EmptyRoom([]),
          broadcast: bridge);
      addTearDown(session.dispose);

      await session.join(url: 'wss://a.invalid', token: 't');
      await session.setScreenShareEnabled(true);

      await session.leave();

      expect(bridge.stopRequests, 2,
          reason: 'exactly the ordered call and the dispose() backstop - a '
              'third would mean _onDisconnected wrongly fired too');
    });
  });
}
