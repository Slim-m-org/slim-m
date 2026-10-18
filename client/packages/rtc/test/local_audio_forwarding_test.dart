// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [LocalAudioState] forwarding: deafen, mute and zero volume stop the SFU sending.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

import 'support/fake_audio_track.dart';

void main() {
  group('server forwarding', () {
    test('deafening stops the SFU sending and undeafening resumes it',
        () async {
      final state = LocalAudioState();
      final voice = FakeAudioTrack('maya');
      final screen = FakeAudioTrack('maya', channel: LocalAudioChannel.screen);

      state.deafened = true;
      await pumpAudioEvents(state, [voice, screen]);
      expect([voice.forwarding, screen.forwarding], [false, false]);
      expect([voice.enabled, screen.enabled], [false, false]);

      state.deafened = false;
      await pumpAudioEvents(state, [voice, screen]);
      expect([voice.forwarding, screen.forwarding], [true, true]);
      expect([voice.enabled, screen.enabled], [true, true]);
    });

    test('a per-user mute and volume zero stop forwarding too', () async {
      final state = LocalAudioState();
      final muted = FakeAudioTrack('ann');
      final quiet = FakeAudioTrack('bo');
      state
        ..setMuted('ann', true)
        ..setVolumeFor('bo', 0);
      await pumpAudioEvents(state, [muted, quiet]);
      expect(muted.forwarding, isFalse);
      expect(quiet.forwarding, isFalse);

      state
        ..setMuted('ann', false)
        ..setVolumeFor('bo', 0.5);
      await pumpAudioEvents(state, [muted, quiet]);
      expect(muted.forwarding, isTrue);
      expect(quiet.forwarding, isTrue);
      expect(quiet.volume, 0.5);
    });

    test('a track that subscribes while deafened is not forwarded', () async {
      final state = LocalAudioState()..deafened = true;
      final late = FakeAudioTrack('maya');
      await pumpAudioEvents(state, [late]);
      late.resubscribe();
      await pumpAudioEvents(state, [late]);
      expect(late.forwarding, isFalse);
      expect(late.enabled, isFalse);
    });

    test('an unchanged reapply tells the SFU nothing new', () async {
      final state = LocalAudioState()..deafened = true;
      final track = FakeAudioTrack('maya');
      await pumpAudioEvents(state, [track]);
      final calls = track.forwardCalls;
      await pumpAudioEvents(state, [track], times: 10);
      expect(track.forwardCalls, calls);
    });
  });
}
