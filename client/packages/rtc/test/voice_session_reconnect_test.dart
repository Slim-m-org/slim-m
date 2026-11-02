// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a call does while LiveKit repairs its own transport: show it, hold the
/// roster, pause the sampling, and rebuild once it is back.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';

import 'support/reconnect_fakes.dart';

List<String> _names(VoiceSession s) => [for (final p in s.participants) p.name];

void main() {
  group('the reconnecting flag', () {
    test('a resume sets it and the reconnected event clears it', () async {
      final call = await JoinedCall.join();
      addTearDown(call.session.dispose);
      final flag = call.session.health.reconnect.active;
      expect(flag.value, isFalse);

      call.room.emit(const lk.RoomResumingEvent());
      await pumpEventQueue();
      expect(flag.value, isTrue);
      expect(call.session.state, VoiceSessionState.connected,
          reason: 'a blip is not a new session state');

      call.room.emit(const lk.RoomReconnectedEvent());
      await pumpEventQueue();
      expect(flag.value, isFalse);
    });

    test('a full restart sets it, and each transition is logged with a time',
        () async {
      final call = await JoinedCall.join();
      addTearDown(call.session.dispose);

      call.room.emit(const lk.RoomReconnectingEvent());
      call.room.emit(const lk.RoomAttemptReconnectEvent(
        attempt: 2,
        maxAttemptsRetry: 10,
        nextRetryDelaysInMs: 300,
      ));
      call.room.emit(const lk.RoomReconnectedEvent());
      await pumpEventQueue();

      final lines = call.log.where((l) => l.startsWith('Call transport'));
      expect(lines, hasLength(3));
      expect(lines.first, contains('reconnecting (restart)'));
      expect(lines.elementAt(1), contains('attempt 2 of 10'));
      expect(lines.last, matches(RegExp(r'reconnected after \d+ ms')));
    });

    test('an attempt event alone marks a reconnect whose start was missed',
        () async {
      final call = await JoinedCall.join();
      addTearDown(call.session.dispose);

      call.room.emit(const lk.RoomAttemptReconnectEvent(
        attempt: 1,
        maxAttemptsRetry: 10,
        nextRetryDelaysInMs: 0,
      ));
      await pumpEventQueue();

      expect(call.session.health.reconnect.active.value, isTrue);
    });

    test('the SDK giving up clears it', () async {
      final call = await JoinedCall.join();
      addTearDown(call.session.dispose);
      call.room.emit(const lk.RoomReconnectingEvent());
      await pumpEventQueue();

      call.room.emit(lk.RoomDisconnectedEvent(
        reason: lk.DisconnectReason.reconnectAttemptsExceeded,
      ));
      await pumpEventQueue();

      expect(call.session.health.reconnect.active.value, isFalse);
      expect(call.session.state, VoiceSessionState.failed);
    });

    test('a blip that ends in the SDK giving up is in that call\'s summary',
        () async {
      final call = await JoinedCall.join();
      addTearDown(call.session.dispose);
      call.room.emit(const lk.RoomReconnectingEvent());
      await pumpEventQueue();

      call.room.emit(lk.RoomDisconnectedEvent(
        reason: lk.DisconnectReason.reconnectAttemptsExceeded,
      ));
      await pumpEventQueue();

      final lines = call.log.where((l) => l.contains('transport blips'));
      expect(lines, hasLength(1));
      expect(lines.single, contains('transport blips=1'));
      expect(call.session.health.reconnect.stats.count, 0,
          reason: 'the next call starts from zero');
      await call.session.leave();
      expect(call.log.where((l) => l.contains('transport blips')), hasLength(1),
          reason: 'the blip is not logged again for the next call');
    });

    test('leaving mid-reconnect clears it', () async {
      final call = await JoinedCall.join();
      addTearDown(call.session.dispose);
      call.room.emit(const lk.RoomResumingEvent());
      await pumpEventQueue();

      await call.session.leave();

      expect(call.session.health.reconnect.active.value, isFalse);
      expect(call.session.glitchWatch.running, isFalse,
          reason: 'clearing the flag on the way out must not restart sampling');
    });

    test('disposing mid-reconnect does not touch the released flag', () async {
      final call = await JoinedCall.join();
      call.room.emit(const lk.RoomResumingEvent());
      await pumpEventQueue();

      await call.session.dispose();
    });
  });

  group('the roster during a reconnect', () {
    test('a full restart that empties the room does not empty the roster',
        () async {
      final call = await JoinedCall.join(people: {'bob': FakePeer('bob')});
      addTearDown(call.session.dispose);
      expect(_names(call.session), ['me', 'bob']);
      final seen = <List<String>>[];
      call.session.participantChanges
          .listen((p) => seen.add([for (final x in p) x.name]));

      call.room.emit(const lk.RoomReconnectingEvent());
      call.room.people.clear();
      call.room
          .emit(lk.ParticipantDisconnectedEvent(participant: FakePeer('bob')));
      await pumpEventQueue();

      expect(_names(call.session), ['me', 'bob']);
      expect(seen, isEmpty,
          reason: 'nothing is emitted while the roster waits');
    });

    test('the roster is rebuilt from the live room, not the old snapshot',
        () async {
      final call = await JoinedCall.join(
        people: {'bob': FakePeer('bob'), 'cy': FakePeer('cy')},
      );
      addTearDown(call.session.dispose);

      call.room.emit(const lk.RoomReconnectingEvent());
      call.room.people
        ..clear()
        ..['cy'] = FakePeer('cy');
      call.room.emit(const lk.RoomReconnectedEvent());
      await pumpEventQueue();

      expect(_names(call.session), ['me', 'cy'],
          reason: 'bob left while we were away and must not reappear');
    });

    test('the roster is rebuilt when the flag clears without the SDK event',
        () async {
      final call = await JoinedCall.join(people: {'bob': FakePeer('bob')});
      addTearDown(call.session.dispose);
      call.room.emit(const lk.RoomReconnectingEvent());
      call.room.people.clear();
      await pumpEventQueue();

      call.session.health.reconnect.ended('no reconnect event');
      await pumpEventQueue();

      expect(_names(call.session), ['me']);
    });

    test('video work carries on while the roster waits', () async {
      final camera = FakeCameraPublication();
      final call = await JoinedCall.join(
        people: {'bob': FakePeer('bob', camera: camera)},
      );
      addTearDown(call.session.dispose);
      call.room.emit(const lk.RoomResumingEvent());
      await pumpEventQueue();
      final before = camera.qualityCalls;

      call.session.setReceiveVideoQuality(ReceiveVideoQuality.dataSaver);
      await pumpEventQueue();

      expect(camera.qualityCalls, greaterThan(before),
          reason: 'a quality change mid-blip must still reach the SFU');
    });
  });

  group('sampling during a reconnect', () {
    test('the ping readout is cleared and sampling resumes afterwards',
        () async {
      final call = await JoinedCall.join();
      addTearDown(call.session.dispose);
      expect(call.session.glitchWatch.running, isTrue);
      call.session.health.pingMs.value = 42;

      call.room.emit(const lk.RoomResumingEvent());
      await pumpEventQueue();
      expect(call.session.health.pingMs.value, isNull);
      expect(call.session.glitchWatch.running, isFalse);

      call.room.emit(const lk.RoomReconnectedEvent());
      await pumpEventQueue();
      expect(call.session.glitchWatch.running, isTrue);
    });
  });

  group('the stall watchdog during a reconnect', () {
    test('a frozen camera is not recovered while the transport repairs itself',
        () async {
      final call = await JoinedCall.join(
        people: {'bob': FakePeer('bob', camera: FakeCameraPublication())},
      );
      addTearDown(call.session.dispose);
      bool stalled() => call.log.any((l) => l.startsWith('Video stalled'));

      call.room.emit(const lk.RoomReconnectingEvent());
      // Longer than the watchdog's grace plus one stats tick.
      await Future<void>.delayed(const Duration(seconds: 5));
      expect(stalled(), isFalse,
          reason: 'frames stand still during a blip, and that is not a stall');

      call.room.emit(const lk.RoomReconnectedEvent());
      for (var i = 0; i < 70 && !stalled(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(stalled(), isTrue,
          reason:
              'a camera still frozen after the blip is recovered as before');
    });
  });
}
