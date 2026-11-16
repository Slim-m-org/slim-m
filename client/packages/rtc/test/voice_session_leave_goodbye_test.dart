// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A hang-up ends the call on screen whether or not the SFU says goodbye.
///
/// livekit waits 10 s for the engine to report the disconnect, and misses the
/// report when it comes while a reconnect attempt is running, so a hang-up
/// during an outage sat on screen for those 10 s.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_rtc/src/voice_call_flow.dart' show kLeaveGoodbyeWait;

import 'support/session_fakes.dart';

/// A room whose goodbye never comes back, and that says when it was disposed.
class _SilentRoom extends ConnectlessRoom {
  static int disposed = 0;

  @override
  Future<void> disconnect() => Completer<void>().future;

  @override
  Future<bool> dispose() {
    disposed++;
    return super.dispose();
  }
}

void main() {
  test('a hang-up does not wait on a goodbye that never comes', () async {
    _SilentRoom.disposed = 0;
    final session = VoiceSession(
      roomFactory: _SilentRoom.new,
      micPort: CountingMic(),
      audioDevices: NoDevices(),
      liveOutput: (room, device) async {},
      inputGate: InputGateMonitor.disabled(),
    );
    addTearDown(session.dispose);
    await session.join(url: 'wss://a.invalid', token: 't');

    await session.leave().timeout(
          kLeaveGoodbyeWait + const Duration(seconds: 3),
          onTimeout: () => fail('the hang-up never finished'),
        );

    expect(session.state, VoiceSessionState.idle);
    expect(_SilentRoom.disposed, 1,
        reason: 'the room is still torn down, which is what stops the media');
  });
}
