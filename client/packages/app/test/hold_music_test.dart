// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Hold music: plays only while alone in a connected call with the setting on,
/// stops the moment that stops being true, and is off by default.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/audio/hold_music_player.dart';
import 'package:slimm_app/src/audio/lounge_tracks.dart';
import 'package:slimm_app/src/providers/hold_music_controller.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/voice_settings_controller.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller_harness.dart';

class _Driven extends VoiceController {
  _Driven(super.ref, VoiceState initial) : super(session: FakeSession()) {
    state = initial;
  }

  void set(VoiceState next) => state = next;
}

class _FakePlayer implements HoldMusicPlayer {
  final calls = <String>[];

  @override
  Future<void> start() async => calls.add('start');
  @override
  Future<void> stop() async => calls.add('stop');

  /// Track switches, kept apart from [calls] so start/stop order reads alone.
  final tracks = <LoungeTrack>[];
  @override
  Future<void> setTrack(LoungeTrack track) async => tracks.add(track);
  @override
  Future<void> dispose() async {}
}

VoiceParticipant _p(String id, {bool local = false}) => VoiceParticipant(
  identity: id,
  name: id,
  isSpeaking: false,
  isMuted: false,
  isLocal: local,
  isScreenSharing: false,
);

final _me = _p('me', local: true);
final _alone = VoiceState(
  channelId: 'c1',
  state: VoiceSessionState.connected,
  participants: [_me],
);

class _Rig {
  _Rig({required bool enabled, VoiceState? initial}) {
    SharedPreferences.setMockInitialValues({
      'slimm.voice.hold_music_enabled': enabled,
    });
    container = ProviderContainer(
      overrides: [
        holdMusicPlayerProvider.overrideWithValue(player),
        voiceControllerProvider.overrideWith(
          (ref) => voice = _Driven(ref, initial ?? _alone),
        ),
      ],
    );
    container.read(voiceSettingsControllerProvider);
    container.read(holdMusicControllerProvider);
  }

  final player = _FakePlayer();
  late final ProviderContainer container;
  late final _Driven voice;
}

void _settle(FakeAsync async) {
  async.flushMicrotasks();
  async.elapse(holdMusicGrace + const Duration(milliseconds: 1));
}

void main() {
  test('the setting is off by default', () {
    expect(const VoiceSettingsState().holdMusicEnabled, isFalse);
  });

  test('alone with the setting on plays after the grace period', () {
    fakeAsync((async) {
      final rig = _Rig(enabled: true);
      async.flushMicrotasks();
      async.elapse(holdMusicGrace - const Duration(seconds: 1));
      expect(rig.player.calls, isEmpty);
      _settle(async);
      expect(rig.player.calls, ['start']);
    });
  });

  test(
    'asking for music while alone starts at once, and turning it off stops',
    () {
      fakeAsync((async) {
        final rig = _Rig(enabled: false);
        async.flushMicrotasks();
        unawaited(
          rig.container
              .read(voiceSettingsControllerProvider.notifier)
              .setHoldMusicEnabled(true),
        );
        rig.container.read(holdMusicControllerProvider).startNow();
        async.flushMicrotasks();
        expect(rig.player.calls, ['start']);
        unawaited(
          rig.container
              .read(voiceSettingsControllerProvider.notifier)
              .setHoldMusicEnabled(false),
        );
        async.flushMicrotasks();
        expect(rig.player.calls, ['start', 'stop']);
      });
    },
  );

  test('alone with the setting off stays silent', () {
    fakeAsync((async) {
      final rig = _Rig(enabled: false);
      _settle(async);
      expect(rig.player.calls, isEmpty);
    });
  });

  test('a second participant stops it, and being alone again restarts it', () {
    fakeAsync((async) {
      final rig = _Rig(enabled: true);
      _settle(async);
      rig.voice.set(_alone.copyWith(participants: [_me, _p('you')]));
      async.flushMicrotasks();
      expect(rig.player.calls, ['start', 'stop']);
      rig.voice.set(_alone);
      _settle(async);
      expect(rig.player.calls, ['start', 'stop', 'start']);
    });
  });

  test('a second participant inside the grace period never starts it', () {
    fakeAsync((async) {
      final rig = _Rig(enabled: true);
      async.flushMicrotasks();
      rig.voice.set(_alone.copyWith(participants: [_me, _p('you')]));
      _settle(async);
      expect(rig.player.calls, isEmpty);
    });
  });

  test('deafening stops it', () {
    fakeAsync((async) {
      final rig = _Rig(enabled: true);
      _settle(async);
      rig.voice.set(_alone.copyWith(deafened: true));
      async.flushMicrotasks();
      expect(rig.player.calls, ['start', 'stop']);
    });
  });

  test('sharing the screen without audio still plays', () {
    fakeAsync((async) {
      final rig = _Rig(
        enabled: true,
        initial: _alone.copyWith(screenSharing: true),
      );
      _settle(async);
      expect(rig.player.calls, ['start']);
    });
  });

  group('shouldPlayHoldMusic', () {
    const on = VoiceSettingsState(holdMusicEnabled: true);

    test('sharing the screen with audio keeps it silent', () {
      final sharing = _alone.copyWith(screenSharing: true);
      expect(shouldPlayHoldMusic(sharing, on), isTrue);
      expect(
        shouldPlayHoldMusic(
          sharing,
          on.copyWith(screenShareIncludeAudio: true),
        ),
        isFalse,
      );
    });

    test('never plays before the call has connected', () {
      expect(
        shouldPlayHoldMusic(
          _alone.copyWith(state: VoiceSessionState.connecting),
          on,
        ),
        isFalse,
      );
    });
  });
}
