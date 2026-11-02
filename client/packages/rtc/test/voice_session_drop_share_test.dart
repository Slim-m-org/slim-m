// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A drop the SFU decided on remembers whether it ended a screen share.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';

import 'support/session_fakes.dart';

class _Bridge implements BroadcastBridge {
  @override
  bool get usesBroadcastExtension => false;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<void> requestStop() async {}

  @override
  set autoPublishEnabled(bool enabled) {}

  @override
  Stream<bool> get broadcastingChanges => const Stream.empty();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(VoiceSession, InstantRoom)> joined({required bool sharing}) async {
    late InstantRoom room;
    final session = VoiceSession(
      roomFactory: () => room = InstantRoom(sharing: sharing),
      micPort: CountingMic(),
      audioDevices: NoDevices(),
      broadcast: _Bridge(),
      liveOutput: (room, device) async {},
      inputGate: InputGateMonitor.disabled(),
    );
    addTearDown(session.dispose);
    await session.join(url: 'wss://a.invalid', token: 't');
    return (session, room);
  }

  void dropRoom(InstantRoom room) => room.events.streamCtrl.add(
        lk.RoomDisconnectedEvent(reason: lk.DisconnectReason.joinFailure),
      );

  test('a drop while sharing is remembered after the roster empties', () async {
    final (session, room) = await joined(sharing: true);
    expect(session.participants.single.isScreenSharing, isTrue);

    dropRoom(room);
    await pumpEventQueue();

    expect(session.participants, isEmpty);
    expect(session.droppedWhileSharing, isTrue);
  });

  test('a drop with no share running remembers none', () async {
    final (session, room) = await joined(sharing: false);

    dropRoom(room);
    await pumpEventQueue();

    expect(session.droppedWhileSharing, isFalse);
  });

  test('the next call starts without the last one\'s share', () async {
    final (session, room) = await joined(sharing: true);
    dropRoom(room);
    await pumpEventQueue();

    await session.join(url: 'wss://a.invalid', token: 't');

    expect(session.droppedWhileSharing, isFalse);
  });
}
