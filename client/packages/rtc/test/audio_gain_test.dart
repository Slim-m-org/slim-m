// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Per-participant volume is offered on every platform: natively through the
/// fork's `setVolume`, and on the web through a Web Audio gain graph.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';

import 'support/session_fakes.dart';

/// A room that connects without an SFU behind it, so a session can be driven
/// far enough to hold state without any signalling.
void main() {
  test('half volume is a clearly quieter -18 dB, full and double stay put', () {
    expect(perceptualParticipantGain(0.5), closeTo(0.125, 1e-9));
    expect(perceptualParticipantGain(0), 0);
    expect(perceptualParticipantGain(1), 1);
    expect(perceptualParticipantGain(1.5), 1.5);
    expect(perceptualParticipantGain(2), 2);
    expect(perceptualParticipantGain(5), kMaxParticipantVolume);
  });

  test('every platform offers the control', () {
    expect(supportsParticipantVolume, isTrue);
  });

  test('clamps into the range the design offers', () {
    expect(clampParticipantVolume(-1), 0.0);
    expect(clampParticipantVolume(0.5), 0.5);
    expect(clampParticipantVolume(kMaxParticipantVolume), 2.0);
    expect(
      clampParticipantVolume(8),
      kMaxParticipantVolume,
      reason: 'native accepts far more than 2.0, and 8x is painfully loud',
    );
  });

  test('a session reports the default until something sets one', () async {
    final session = VoiceSession(roomFactory: ConnectlessRoom.new);
    addTearDown(session.dispose);

    expect(session.volumeFor('maya'), kDefaultParticipantVolume);

    await session.setVolumeFor('maya', 1.3);
    expect(session.volumeFor('maya'), closeTo(1.3, 0.0001));
    expect(
      session.volumeFor('someone-else'),
      kDefaultParticipantVolume,
      reason: 'volume is per participant, not per session',
    );
  });

  test('stores clamped, so no caller can stash a value the UI cannot show',
      () async {
    final session = VoiceSession(roomFactory: ConnectlessRoom.new);
    addTearDown(session.dispose);

    await session.setVolumeFor('maya', 99);
    expect(session.volumeFor('maya'), kMaxParticipantVolume);

    await session.setVolumeFor('maya', -4);
    expect(session.volumeFor('maya'), 0.0);
  });

  test('applying gain to a track never throws, whatever the platform does',
      () async {
    // Fired unawaited from a room-event loop, so a throw would be a zone error.
    expect(
      () => applyParticipantVolume(_UnusableTrack(), 1.5),
      returnsNormally,
    );
  });
}

/// A track object that is not backed by anything, standing in for a native
/// lookup that cannot find the track.
class _UnusableTrack implements lk.Track {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
