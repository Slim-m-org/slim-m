// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [LocalAudioState]: what reaches this listener's ears, and the two things
/// that pull in opposite directions.
///
/// It is reapplied on every room event, because that is what catches a track
/// that resubscribed at full volume with nothing to announce it. But the
/// caller's listener is a catch-all, and `ActiveSpeakersChanged` arrives
/// several times a second while anybody talks, so reapplying unconditionally
/// spends a platform round trip per remote track per event to set values
/// already set.
///
/// So these tests are written in pairs: one that a redundant push is not
/// made, and one that the push which is not redundant still is. A cache that
/// only ever skipped would pass the first half alone, which is why the second
/// half is here.
///
/// Every track carries its own `enabled`/`volume` state and the assertions
/// read that state as well as the call counts, the rule
/// `video_subscription_culler_test.dart` sets: proving a method ran says
/// nothing about whether it ran on the right track with the right value.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' show LogLevel;
import 'package:slimm_rtc/rtc.dart';

import 'support/fake_audio_track.dart';

void main() {
  test(
    'the first apply pushes, and an unchanged reapply pushes nothing',
    () async {
      final state = LocalAudioState();
      final track = FakeAudioTrack('maya');

      await pumpAudioEvents(state, [track]);
      final afterFirst = track.platformCalls;
      expect(
        afterFirst,
        greaterThan(0),
        reason: 'the first apply has nothing cached and must actually push',
      );

      await pumpAudioEvents(state, [track], times: 20);
      expect(
        track.platformCalls,
        afterFirst,
        reason:
            'twenty ActiveSpeakersChanged events must cost no platform calls',
      );
      expect(track.enabled, isTrue, reason: 'and the track is still audible');
    },
  );

  test('a resubscribed track is reapplied, cache or no cache', () async {
    final state = LocalAudioState();
    final track = FakeAudioTrack('maya');
    state.setVolumeFor('maya', 1.5);

    await pumpAudioEvents(state, [track], times: 5);
    expect(track.volume, closeTo(1.5, 0.0001));

    // The blip: LiveKit hands back a new platform object at source default.
    track.resubscribe();
    expect(track.volume, kDefaultParticipantVolume);

    await pumpAudioEvents(state, [track]);
    expect(
      track.volume,
      closeTo(1.5, 0.0001),
      reason: 'a resubscribe must not be mistaken for a state already applied',
    );
  });

  test('muting one participant pushes only to that participant', () async {
    final state = LocalAudioState();
    final maya = FakeAudioTrack('maya');
    final ines = FakeAudioTrack('ines');

    await pumpAudioEvents(state, [maya, ines]);
    final inesBefore = ines.platformCalls;

    state.setMuted('maya', true);
    await pumpAudioEvents(state, [maya, ines], times: 5);

    expect(maya.enabled, isFalse, reason: 'the muted one is silenced');
    expect(ines.enabled, isTrue, reason: 'and nobody else is');
    expect(
      ines.platformCalls,
      inesBefore,
      reason: 'an unrelated participant costs nothing when one is muted',
    );
    expect(
      maya.disableCalls,
      1,
      reason: 'and the mute is pushed once, not per event',
    );
  });

  test(
    'deafening silences everyone, and undeafening restores each volume',
    () async {
      final state = LocalAudioState();
      final maya = FakeAudioTrack('maya');
      final ines = FakeAudioTrack('ines');
      state.setVolumeFor('ines', 0.4);
      await pumpAudioEvents(state, [maya, ines]);

      state.deafened = true;
      await pumpAudioEvents(state, [maya, ines], times: 5);
      expect(maya.enabled, isFalse);
      expect(ines.enabled, isFalse);

      state.deafened = false;
      await pumpAudioEvents(state, [maya, ines], times: 5);
      expect(maya.enabled, isTrue);
      expect(ines.enabled, isTrue);
      expect(
        ines.volume,
        closeTo(0.4, 0.0001),
        reason: 'undeafening restores the chosen gain, not the source default',
      );
    },
  );

  test('a volume change is pushed, and only the change', () async {
    final state = LocalAudioState();
    final track = FakeAudioTrack('maya');
    await pumpAudioEvents(state, [track], times: 3);
    final before = track.volumeCalls;

    state.setVolumeFor('maya', 0.8);
    await pumpAudioEvents(state, [track], times: 5);

    expect(track.volume, closeTo(0.8, 0.0001));
    expect(
      track.volumeCalls,
      before + 1,
      reason: 'five events after one slider move is one push, not five',
    );
  });

  test('a moved slider during a mute costs nothing until the unmute', () async {
    final state = LocalAudioState();
    final track = FakeAudioTrack('maya');
    await pumpAudioEvents(state, [track]);

    state.setMuted('maya', true);
    await pumpAudioEvents(state, [track]);
    final whileMuted = track.platformCalls;

    state.setVolumeFor('maya', 1.9);
    await pumpAudioEvents(state, [track], times: 5);
    expect(
      track.platformCalls,
      whileMuted,
      reason: 'volume is not pushed while silenced, so nothing is resent',
    );

    state.setMuted('maya', false);
    await pumpAudioEvents(state, [track]);
    expect(track.enabled, isTrue);
    expect(
      track.volume,
      closeTo(1.9, 0.0001),
      reason: 'the unmute applies the gain chosen while it was silent',
    );
  });

  test('a failed push is retried rather than remembered as done', () async {
    final state = LocalAudioState();
    final track = FakeAudioTrack('maya');
    final boom = Exception('platform said no');
    track.failure = boom;

    final failure = await state.applyToRefs([track.ref]);
    expect(failure, same(boom), reason: 'the failure is returned, not thrown');
    final afterFailure = track.platformCalls;

    // The condition clears the way a transient platform error does.
    track.failure = null;
    await pumpAudioEvents(state, [track]);
    expect(
      track.platformCalls,
      greaterThan(afterFailure),
      reason: 'a push that failed must not be cached as successfully applied',
    );
    expect(track.enabled, isTrue, reason: 'and the retry actually lands');
  });

  test('two tracks on one participant are both kept in step', () async {
    final state = LocalAudioState();
    final first = FakeAudioTrack('maya');
    final second = FakeAudioTrack('maya');

    await pumpAudioEvents(state, [first, second]);
    state.setMuted('maya', true);
    await pumpAudioEvents(state, [first, second], times: 3);

    expect(first.enabled, isFalse);
    expect(
      second.enabled,
      isFalse,
      reason: 'the cache is per track, so a second track is not skipped',
    );
  });

  /// The failure the cache can cause that unconditional reapplication could
  /// not, and the reason this file models `Track._active` at all.
  ///
  /// `addSubscribedMediaTrack` emits `TrackSubscribedEvent` and only then
  /// awaits `track.start()`, which awaits `startCapture()` before it sets
  /// `_active`. The emitter is asynchronous, so the catch-all room listener
  /// runs first, with the new track inactive, and the `disable()` it pushes
  /// does nothing and says nothing. `RemoteTrack.start()` then calls
  /// `enable()` of its own accord.
  ///
  /// So the push is dropped, the track is audible, and a cache that believed
  /// the push landed will skip every later event. Before the cache existed the
  /// next event re-pushed and fixed it within one event cycle.
  test('a track that resubscribes while muted does not come back audible',
      () async {
    final state = LocalAudioState();
    final track = FakeAudioTrack('maya');
    state.setMuted('maya', true);
    await pumpAudioEvents(state, [track]);
    expect(track.enabled, isFalse, reason: 'silenced to begin with');

    track.resubscribeButNotYetStarted();
    await pumpAudioEvents(state, [track]);
    track.finishStarting();

    await pumpAudioEvents(state, [track], times: 10);

    expect(
      track.enabled,
      isFalse,
      reason: 'a muted participant must not be audible after a resubscribe',
    );
  });

  test('a track still inactive when muted is silenced once it starts',
      () async {
    final state = LocalAudioState();
    final track = FakeAudioTrack('maya')..active = false;
    state.setMuted('maya', true);

    await pumpAudioEvents(state, [track], times: 3);
    expect(
      track.enabled,
      isTrue,
      reason: 'the fixture is real: an inactive track cannot be pushed to',
    );

    track.active = true;
    await pumpAudioEvents(state, [track]);
    expect(
      track.enabled,
      isFalse,
      reason: 'the first event after it starts must silence it',
    );
  });

  /// The production caller fires this without awaiting - `_refreshParticipants`
  /// does `unawaited(_applyLocalAudioState(room))` on every room event - so two
  /// events arriving faster than a platform round trip really do overlap over
  /// the same state. Every other test here drives them one at a time.
  test('overlapping applies still settle on the chosen state', () async {
    final state = LocalAudioState();
    final maya = FakeAudioTrack('maya');
    final ines = FakeAudioTrack('ines');
    state.setMuted('maya', true);
    state.setVolumeFor('ines', 1.7);

    await Future.wait([
      for (var i = 0; i < 8; i++)
        state.applyToRefs([maya, ines].map((t) => t.ref)),
    ]);

    expect(maya.enabled, isFalse, reason: 'the muted one ends silenced');
    expect(ines.enabled, isTrue, reason: 'and the other stays audible');
    expect(ines.volume, closeTo(1.7, 0.0001), reason: 'at the chosen gain');

    // And the racing burst has not left a belief that blocks later corrections.
    maya.enabled = true;
    await pumpAudioEvents(state, [maya, ines]);
    expect(
      maya.enabled,
      isFalse,
      reason: 'a track re-enabled behind our back is still corrected',
    );
  });

  group('keyed by source', () {
    test('screen audio takes its own gain, apart from the voice', () async {
      final state = LocalAudioState();
      final voice = FakeAudioTrack('maya');
      final screen = FakeAudioTrack('maya', channel: LocalAudioChannel.screen);
      state.setVolumeFor('maya', 0.4);
      state.setVolumeFor('maya', 1.8, channel: LocalAudioChannel.screen);

      await pumpAudioEvents(state, [voice, screen]);

      expect(voice.volume, closeTo(0.4, 0.0001));
      expect(screen.volume, closeTo(1.8, 0.0001));
      expect(state.volumeFor('maya'), closeTo(0.4, 0.0001));
      expect(
        state.volumeFor('maya', channel: LocalAudioChannel.screen),
        closeTo(1.8, 0.0001),
      );
    });

    test('muting the screen audio leaves the voice audible', () async {
      final state = LocalAudioState();
      final voice = FakeAudioTrack('maya');
      final screen = FakeAudioTrack('maya', channel: LocalAudioChannel.screen);
      state.setScreenMuted('maya', true);

      await pumpAudioEvents(state, [voice, screen]);

      expect(voice.enabled, isTrue);
      expect(screen.enabled, isFalse);

      state.setScreenMuted('maya', false);
      await pumpAudioEvents(state, [voice, screen]);
      expect(screen.enabled, isTrue);
    });

    test('muting the person still silences both', () async {
      final state = LocalAudioState();
      final voice = FakeAudioTrack('maya');
      final screen = FakeAudioTrack('maya', channel: LocalAudioChannel.screen);
      state.setMuted('maya', true);

      await pumpAudioEvents(state, [voice, screen]);

      expect(voice.enabled, isFalse);
      expect(screen.enabled, isFalse);
    });
  });

  group('failures', () {
    test('a failed gain push is reported and not remembered', () async {
      final state = LocalAudioState();
      final track = FakeAudioTrack('maya');
      state.setVolumeFor('maya', 1.5);
      track.failure = StateError('no such track');

      final failure = await state.applyToRefs([track.ref]);

      expect(failure, isNotNull);
      expect(state.failureFor('maya'), isNotNull);

      track.failure = null;
      final before = track.volumeCalls;
      expect(await state.applyToRefs([track.ref]), isNull);
      expect(
        track.volumeCalls,
        greaterThan(before),
        reason: 'the failure was never cached as applied, so it is retried',
      );
      expect(track.volume, closeTo(1.5, 0.0001));
      expect(state.failureFor('maya'), isNull);
    });

    test('a failure is held against the channel that failed', () async {
      final state = LocalAudioState();
      final voice = FakeAudioTrack('maya');
      final screen = FakeAudioTrack('maya', channel: LocalAudioChannel.screen);
      screen.failure = StateError('nope');

      await state.applyToRefs([voice.ref, screen.ref]);

      expect(state.failureFor('maya'), isNull);
      expect(
        state.failureFor('maya', channel: LocalAudioChannel.screen),
        isNotNull,
      );
    });
  });

  test('a slow push never lets a stale volume land last', () async {
    final state = LocalAudioState();
    final landed = <double>[];
    final gate = <Completer<void>>[];
    final track = FakeAudioTrack('maya');
    final ref = (
      identity: 'maya',
      channel: LocalAudioChannel.voice,
      trackId: 'maya',
      track: Object(),
      isAudible: () => true,
      enable: () async {},
      disable: () async {},
      startForwarding: () async {},
      stopForwarding: () async {},
      setVolume: (double v) async {
        final c = Completer<void>();
        gate.add(c);
        await c.future;
        landed.add(v);
        return null;
      },
    );
    expect(track, isNotNull);

    state.setVolumeFor('maya', 0.5);
    final first = state.applyToRefs([ref]);
    await Future<void>.delayed(Duration.zero);
    state.setVolumeFor('maya', 1.0);
    state.setVolumeFor('maya', 1.7);
    final second = state.applyToRefs([ref]);
    final third = state.applyToRefs([ref]);

    gate.first.complete();
    await Future<void>.delayed(Duration.zero);
    expect(gate, hasLength(2), reason: 'one follow-up pass, none overlapping');
    gate.last.complete();
    await Future.wait([first, second, third]);

    expect(landed, [0.5, 1.7]);
  });

  test('every push is logged with identity, source, gain, track and result',
      () async {
    final lines = <String>[];
    final state = LocalAudioState()
      ..log = (m, {level = LogLevel.info}) => lines.add(m);
    final track = FakeAudioTrack('maya', channel: LocalAudioChannel.screen);
    state.setVolumeFor('maya', 1.5, channel: LocalAudioChannel.screen);

    await state.applyToRefs([track.ref]);
    track.failure = StateError('boom');
    state.setVolumeFor('maya', 0.5, channel: LocalAudioChannel.screen);
    await state.applyToRefs([track.ref]);

    expect(lines.first, contains('x1.5 for screen audio of maya'));
    expect(lines.first, contains('applied'));
    expect(lines.last, contains('x0.5'));
    expect(lines.last, contains('failed: Bad state: boom'));
  });

  test('a push the cache skips is logged once per track and gain', () async {
    final lines = <String>[];
    final state = LocalAudioState()
      ..log = (m, {level = LogLevel.info}) => lines.add(m);
    final track = FakeAudioTrack('maya');
    state.setVolumeFor('maya', 1.5);

    await state.applyToRefs([track.ref]);
    await state.applyToRefs([track.ref]);
    await state.applyToRefs([track.ref]);

    expect(lines, hasLength(2));
    expect(lines.last, contains('already applied, push skipped'));
  });
}
