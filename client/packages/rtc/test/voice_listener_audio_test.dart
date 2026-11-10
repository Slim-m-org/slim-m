// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What one listener hears: deafen, mute and gain that never reach the room.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/src/voice_listener_audio.dart';

import 'support/session_fakes.dart';

void main() {
  late lk.Room? room;
  late int refreshes;
  late List<Object> errors;
  late VoiceListenerAudio listener;

  setUp(() {
    room = null;
    refreshes = 0;
    errors = [];
    listener = VoiceListenerAudio(
      VoiceListenerAudioHost(
        room: () => room,
        noteError: errors.add,
        refresh: () => refreshes++,
      ),
    );
  });

  test('a mute is remembered and refreshes the roster, call or no call',
      () async {
    await listener.setLocallyMuted('ana', true);

    expect(listener.isLocallyMuted('ana'), isTrue);
    expect(listener.isLocallyMuted('bo'), isFalse);
    expect(refreshes, 1);
  });

  test('a volume is clamped to what the UI offers and kept apart per channel',
      () async {
    await listener.setVolumeFor('ana', 9);
    await listener.setScreenVolumeFor('ana', 0.25);

    expect(listener.volumeFor('ana'), 2.0);
    expect(listener.screenVolumeFor('ana'), 0.25);
    expect(listener.volumeFor('bo'), 1.0);
  });

  test('a screen share mute does not silence the voice', () async {
    await listener.setScreenAudioMuted('ana', true);

    expect(listener.isScreenAudioMuted('ana'), isTrue);
    expect(listener.isLocallyMuted('ana'), isFalse);
  });

  test('deafening needs a call to affect', () async {
    expect(await listener.setDeafened(true), isFalse);
    expect(listener.deafened, isFalse);

    room = InstantRoom();
    expect(await listener.setDeafened(true), isTrue);
    expect(listener.deafened, isTrue);
    expect(refreshes, 1);
    expect(errors, isEmpty);
  });

  test('a new call clears deafen and mutes but keeps every gain', () async {
    await listener.setLocallyMuted('ana', true);
    await listener.setScreenAudioMuted('ana', true);
    await listener.setVolumeFor('ana', 0.5);
    room = InstantRoom();
    await listener.setDeafened(true);

    listener.resetForNewCall();

    expect(listener.deafened, isFalse);
    expect(listener.isLocallyMuted('ana'), isFalse);
    expect(listener.isScreenAudioMuted('ana'), isFalse);
    expect(listener.volumeFor('ana'), 0.5);
  });

  test('nobody the listener has not touched has a gain failure', () {
    expect(listener.volumeFailureFor('ana'), isNull);
    expect(listener.volumeFailureFor('ana', screen: true), isNull);
    expect(listener.hasScreenAudio('ana'), isFalse);
  });
}
