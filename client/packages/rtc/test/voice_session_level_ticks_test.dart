// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The SFU re-reports a talker's level about twice a second; the roster must not
/// change for it, or every watcher of the call rebuilds on each tick.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';

import 'support/reconnect_fakes.dart';

const _speakersChanged = lk.ActiveSpeakersChangedEvent(speakers: []);

VoiceParticipant _person({double level = 0}) => VoiceParticipant(
      identity: 'bob',
      name: 'bob',
      isSpeaking: true,
      isMuted: false,
      isLocal: false,
      isScreenSharing: false,
      audioLevel: level,
    );

void main() {
  test('two rosters that differ only in level are the same roster', () {
    expect(_person(level: 0.1), _person(level: 0.9));
    expect(_person(level: 0.1).hashCode, _person(level: 0.9).hashCode);
  });

  test('a level tick does not emit a new roster', () async {
    final bob = FakePeer('bob');
    final call = await JoinedCall.join(people: {'bob': bob});
    addTearDown(call.session.dispose);
    var emitted = 0;
    call.session.participantChanges.listen((_) => emitted++);

    for (final level in [0.2, 0.35, 0.5, 0.41]) {
      bob.audioLevel = level;
      call.room.emit(_speakersChanged);
      await pumpEventQueue();
    }

    expect(emitted, 0);
  });

  test('a real roster change still emits', () async {
    final call = await JoinedCall.join(people: {'bob': FakePeer('bob')});
    addTearDown(call.session.dispose);
    var emitted = 0;
    call.session.participantChanges.listen((_) => emitted++);

    call.room.people['cy'] = FakePeer('cy');
    call.room.emit(_speakersChanged);
    await pumpEventQueue();

    expect(emitted, 1);
  });

  group('your own level', () {
    test('is reported as it changes, and only then', () async {
      final call = await JoinedCall.join();
      addTearDown(call.session.dispose);
      final levels = <double>[];
      call.session.localAudioLevels.listen(levels.add);

      for (final level in [0.4, 0.4, 0.7]) {
        call.room.localLevel = level;
        call.room.emit(_speakersChanged);
        await pumpEventQueue();
      }

      expect(levels, [0.4, 0.7]);
    });

    test('drops to zero when the call ends', () async {
      final call = await JoinedCall.join();
      addTearDown(call.session.dispose);
      call.room.localLevel = 0.6;
      call.room.emit(_speakersChanged);
      await pumpEventQueue();
      final levels = <double>[];
      call.session.localAudioLevels.listen(levels.add);

      await call.session.leave();
      await pumpEventQueue();

      expect(levels, [0.0]);
    });

    test('drops to zero when the room drops mid-speech', () async {
      final call = await JoinedCall.join();
      addTearDown(call.session.dispose);
      call.room.localLevel = 0.6;
      call.room.emit(_speakersChanged);
      await pumpEventQueue();
      final levels = <double>[];
      call.session.localAudioLevels.listen(levels.add);

      call.room.emit(lk.RoomDisconnectedEvent(
        reason: lk.DisconnectReason.reconnectAttemptsExceeded,
      ));
      await pumpEventQueue();

      expect(call.session.state, VoiceSessionState.failed);
      expect(levels, [0.0]);
    });

    test('drops to zero while a full restart has no roster to report',
        () async {
      final call = await JoinedCall.join();
      addTearDown(call.session.dispose);
      call.room.localLevel = 0.6;
      call.room.emit(_speakersChanged);
      await pumpEventQueue();
      final levels = <double>[];
      call.session.localAudioLevels.listen(levels.add);

      call.room.emit(const lk.RoomReconnectingEvent());
      await pumpEventQueue();

      expect(levels, [0.0]);
    });
  });
}
