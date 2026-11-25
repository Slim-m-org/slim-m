// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A Speak grant or revoke the SFU pushes mid-call reaches the session without a rejoin.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import 'package:slimm_rtc/rtc.dart';

import 'support/session_fakes.dart';

class _LocalPerson extends Fake implements lk.LocalParticipant {}

lk.ParticipantPermissionsUpdatedEvent _permissions(
        {required bool canPublish}) =>
    lk.ParticipantPermissionsUpdatedEvent(
      participant: _LocalPerson(),
      permissions: lk.ParticipantPermissions(canPublish: canPublish),
      oldPermissions: lk.ParticipantPermissions(canPublish: !canPublish),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<({InstantRoom room, CountingMic mic, VoiceSession session})> join({
    required bool canPublish,
  }) async {
    final mic = CountingMic();
    final room = InstantRoom();
    final session = instantSession(mic: mic, room: room);
    addTearDown(session.dispose);
    await session.join(
      url: 'wss://a.invalid',
      token: 't',
      microphoneEnabled: false,
      canPublish: canPublish,
    );
    return (room: room, mic: mic, session: session);
  }

  test('a grant mid-call is reported and lets push to talk ready the mic',
      () async {
    final call = await join(canPublish: false);
    final seen = <bool>[];
    call.session.publishPermission.listen(seen.add);

    // ignore: invalid_use_of_internal_member
    call.room.events.emit(_permissions(canPublish: true));
    await pumpEventQueue();
    await call.session.setKeepMicReady(true);

    expect(seen, [true]);
    expect(call.mic.reopens, 1);
  });

  test('a revoke mid-call is reported and stops the mic being readied',
      () async {
    final call = await join(canPublish: true);
    final seen = <bool>[];
    call.session.publishPermission.listen(seen.add);

    // ignore: invalid_use_of_internal_member
    call.room.events.emit(_permissions(canPublish: false));
    await pumpEventQueue();
    await call.session.setKeepMicReady(true);

    expect(seen, [false]);
    expect(call.mic.reopens, 0);
  });
}
