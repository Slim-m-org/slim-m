// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Starts and stops the local hold music from the call's own state.
///
/// Plays only while connected, alone (`isAloneInCall`), enabled, not deafened
/// and not sharing a screen with audio. The player is this device's own, so
/// nothing here can reach the room.
library;

import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../../audio/hold_music_player.dart';
import '../../../audio/lounge_tracks.dart';
import '../../../providers/app_lifecycle.dart';
import 'call_solo.dart';
import 'voice_controller.dart';
import 'voice_settings_controller.dart';

const holdMusicGrace = Duration(seconds: 3);

/// A pause this long frees the native player; resuming after it restarts the track.
const holdMusicPauseRelease = Duration(minutes: 10);

/// True while the solo call's music is paused mid-track.
final holdMusicPausedProvider = StateProvider<bool>((ref) => false);

bool shouldPlayHoldMusic(
  VoiceState voice,
  VoiceSettingsState settings, {
  bool backgrounded = false,
}) =>
    !backgrounded &&
    settings.holdMusicEnabled &&
    voice.state == VoiceSessionState.connected &&
    isAloneInCall(voice.participants) &&
    !voice.deafened &&
    !(voice.screenSharing && settings.screenShareIncludeAudio);

class HoldMusicController {
  HoldMusicController(
    this._ref, {
    required HoldMusicPlayer player,
    Duration? grace,
    Duration? pauseRelease,
  }) : _player = player,
       _grace = grace ?? holdMusicGrace,
       _pauseRelease = pauseRelease ?? holdMusicPauseRelease {
    _ref.listen<VoiceState>(voiceControllerProvider, (_, _) => _evaluate());
    _ref.listen<VoiceSettingsState>(
      voiceSettingsControllerProvider,
      (_, _) => _evaluate(),
    );
    if (_mobile) {
      _ref.listen<AppLifecycleState>(
        appLifecycleProvider,
        (_, _) => _evaluate(),
      );
    }
    _ref.listen<LoungeTrack>(
      voiceSettingsControllerProvider.select((s) => s.holdMusicTrack),
      (_, track) => unawaited(_player.setTrack(track)),
      fireImmediately: true,
    );
    _ref.listen<double>(
      voiceSettingsControllerProvider.select((s) => s.holdMusicVolume),
      (_, volume) => unawaited(_player.setVolume(volume)),
      fireImmediately: true,
    );
    _evaluate();
  }

  final Ref _ref;
  late final bool _mobile = _ref.read(mobileLifecycleHostProvider);
  final HoldMusicPlayer _player;
  final Duration _grace;
  final Duration _pauseRelease;
  Timer? _pending;
  Timer? _releaseTimer;
  bool _playing = false;

  bool get _paused => _ref.read(holdMusicPausedProvider);

  void _setPaused(bool paused) {
    if (_paused != paused) {
      _ref.read(holdMusicPausedProvider.notifier).state = paused;
    }
  }

  /// Holds the track where it is, or holds back a start still in its grace.
  void pause() {
    if (_paused) return;
    // Still in the start grace: nothing plays yet, so the pause just holds the start back.
    if (!_playing) {
      if (_pending == null) return;
      _pending?.cancel();
      _pending = null;
      _setPaused(true);
      return;
    }
    _setPaused(true);
    unawaited(_player.pause());
    _releaseTimer = Timer(_pauseRelease, () {
      _releaseTimer = null;
      _playing = false;
      unawaited(_player.stop());
    });
  }

  /// Carries on from the paused spot, or restarts the track once a long pause freed the player.
  void resume() {
    if (!_paused) return;
    _setPaused(false);
    final released = _releaseTimer == null;
    _releaseTimer?.cancel();
    _releaseTimer = null;
    if (released) {
      _evaluate(immediate: true);
    } else {
      unawaited(_player.resume());
    }
  }

  /// Skips the grace for a person who just asked for music, if it is due at all.
  void startNow() => _evaluate(immediate: true);

  void _evaluate({bool immediate = false}) {
    final want = shouldPlayHoldMusic(
      _ref.read(voiceControllerProvider),
      _ref.read(voiceSettingsControllerProvider),
      backgrounded:
          _mobile &&
          isBackgroundedOnPhone(_ref.read(appLifecycleProvider), mobile: true),
    );
    if (!want) {
      _pending?.cancel();
      _pending = null;
      _releaseTimer?.cancel();
      _releaseTimer = null;
      _setPaused(false);
      if (_playing) {
        _playing = false;
        unawaited(_player.stop());
      }
      return;
    }
    if (_playing || _paused) return;
    if (immediate) {
      _pending?.cancel();
      _pending = null;
      _playing = true;
      unawaited(_player.start());
      return;
    }
    if (_pending != null) return;
    _pending = Timer(_grace, () {
      _pending = null;
      _playing = true;
      unawaited(_player.start());
    });
  }

  void dispose() {
    _pending?.cancel();
    _releaseTimer?.cancel();
    if (_playing) unawaited(_player.stop());
  }
}

final holdMusicControllerProvider = Provider<HoldMusicController>((ref) {
  final controller = HoldMusicController(
    ref,
    player: ref.watch(holdMusicPlayerProvider),
  );
  ref.onDispose(controller.dispose);
  return controller;
});
