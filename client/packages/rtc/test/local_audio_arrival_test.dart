// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A track that arrives mid-call or on rejoin must start at the listener's
/// choice, not play at full volume until the next apply pass reaches it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

LocalAudioRef _ref(
  String identity, {
  LocalAudioChannel channel = LocalAudioChannel.voice,
  String? trackId,
}) =>
    (
      identity: identity,
      channel: channel,
      trackId: trackId ?? 'track-$identity',
      track: Object(),
      isAudible: () => true,
      enable: () async {},
      disable: () async {},
      startForwarding: () async {},
      stopForwarding: () async {},
      setVolume: (_) async => null,
    );

void main() {
  group('arrivalGain', () {
    test('an untouched participant needs no hold', () {
      expect(LocalAudioState().arrivalGain('maya', LocalAudioChannel.voice),
          isNull);
    });

    test('a saved volume is the starting gain, zero included', () {
      final state = LocalAudioState()
        ..setVolumeFor('maya', 0)
        ..setVolumeFor('li', 0.5);

      expect(state.arrivalGain('maya', LocalAudioChannel.voice), 0);
      expect(state.arrivalGain('li', LocalAudioChannel.voice), 0.5);
    });

    test('deafening, muting and a muted screen start silent', () {
      final state = LocalAudioState()
        ..setMuted('maya', true)
        ..setScreenMuted('li', true);

      expect(state.arrivalGain('maya', LocalAudioChannel.voice), 0);
      expect(state.arrivalGain('li', LocalAudioChannel.screen), 0);
      expect(state.arrivalGain('li', LocalAudioChannel.voice), isNull);
      state.deafened = true;
      expect(state.arrivalGain('bo', LocalAudioChannel.voice), 0);
    });

    test('the screen channel keeps its own volume', () {
      final state = LocalAudioState()
        ..setVolumeFor('maya', 0.25, channel: LocalAudioChannel.screen);

      expect(state.arrivalGain('maya', LocalAudioChannel.screen), 0.25);
      expect(state.arrivalGain('maya', LocalAudioChannel.voice), isNull);
    });
  });

  group('holdArrival', () {
    test('holds only the arrived track, at that person\'s gain', () {
      final state = LocalAudioState()..setVolumeFor('maya', 0);
      final held = <String, double>{};

      state.holdArrival(
        [_ref('maya'), _ref('li')],
        'track-maya',
        (id, gain) => held[id] = gain,
      );

      expect(held, {'track-maya': 0.0});
    });

    test('leaves a track at full volume alone', () {
      final held = <String, double>{};

      LocalAudioState().holdArrival(
        [_ref('maya')],
        'track-maya',
        (id, gain) => held[id] = gain,
      );

      expect(held, isEmpty);
    });

    test('ignores an element that belongs to no known track', () {
      final state = LocalAudioState()..deafened = true;
      final held = <String, double>{};

      state.holdArrival([_ref('maya')], 'other', (id, gain) => held[id] = gain);

      expect(held, isEmpty);
    });
  });
}
