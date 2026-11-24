// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A disconnect the SFU forces must release capture a failed restart left running.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';

import 'support/reconnect_fakes.dart';
import 'support/session_fakes.dart';

class _SweptMic extends CountingMic {
  int sweeps = 0;

  @override
  Future<void> stopUnpublished() async => sweeps++;
}

void main() {
  test('an SFU disconnect sweeps the microphone left capturing', () async {
    final mic = _SweptMic();
    late PeopleRoom room;
    final session = VoiceSession(
      roomFactory: () => room = PeopleRoom(),
      micPort: mic,
      audioDevices: NoDevices(),
      liveOutput: (room, device) async {},
      inputGate: InputGateMonitor.disabled(),
    );
    addTearDown(session.dispose);
    await session.join(url: 'wss://a.invalid', token: 't');

    room.emit(lk.RoomDisconnectedEvent(
      reason: lk.DisconnectReason.reconnectAttemptsExceeded,
    ));
    await pumpEventQueue();

    expect(session.state, VoiceSessionState.failed);
    expect(mic.sweeps, 1);
  });
}
