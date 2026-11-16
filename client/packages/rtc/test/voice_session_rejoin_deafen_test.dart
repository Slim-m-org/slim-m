// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Deafen belongs to the listener, not to one connection: a call that comes
/// back, or a switch to another one, does not start playing again by itself.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';

import 'support/reconnect_fakes.dart';
import 'support/session_fakes.dart';

VoiceSession _session(List<PeopleRoom> rooms) => VoiceSession(
      roomFactory: () {
        final room = PeopleRoom();
        rooms.add(room);
        return room;
      },
      micPort: CountingMic(),
      audioDevices: NoDevices(),
      liveOutput: (room, device) async {},
      inputGate: InputGateMonitor.disabled(),
    );

Future<void> _join(VoiceSession session) =>
    session.join(url: 'wss://a.invalid', token: 't');

void main() {
  test('a call the SFU dropped comes back deafened', () async {
    final rooms = <PeopleRoom>[];
    final session = _session(rooms);
    addTearDown(session.dispose);
    await _join(session);
    expect(await session.setDeafened(true), isTrue);

    rooms.single.emit(lk.RoomDisconnectedEvent(
      reason: lk.DisconnectReason.reconnectAttemptsExceeded,
    ));
    await pumpEventQueue();
    expect(session.state, VoiceSessionState.failed);
    await _join(session);

    expect(session.state, VoiceSessionState.connected);
    expect(session.deafened, isTrue);
  });

  test('joining another call straight from one keeps the listener deafened',
      () async {
    final session = _session([]);
    addTearDown(session.dispose);
    await _join(session);
    await session.setDeafened(true);

    await _join(session);

    expect(session.deafened, isTrue);
  });

  test('leaving undeafens, so the next call starts heard', () async {
    final session = _session([]);
    addTearDown(session.dispose);
    await _join(session);
    await session.setDeafened(true);

    await session.leave();
    await _join(session);

    expect(session.deafened, isFalse);
  });
}
