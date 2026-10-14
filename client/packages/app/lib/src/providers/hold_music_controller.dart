// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Starts and stops the local hold music from the call's own state.
///
/// Plays only while connected, alone (`isAloneInCall`), enabled, not deafened
/// and not sharing a screen with audio. The player is this device's own, so
/// nothing here can reach the room.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart';

import '../audio/hold_music_player.dart';
import '../audio/lounge_tracks.dart';
import 'call_solo.dart';
import 'voice_controller.dart';
import 'voice_settings_controller.dart';

const holdMusicGrace = Duration(seconds: 3);

bool shouldPlayHoldMusic(VoiceState voice, VoiceSettingsState settings) =>
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
  }) : _player = player,
       _grace = grace ?? holdMusicGrace {
    _ref.listen<VoiceState>(voiceControllerProvider, (_, _) => _evaluate());
    _ref.listen<VoiceSettingsState>(
      voiceSettingsControllerProvider,
      (_, _) => _evaluate(),
    );
    _ref.listen<LoungeTrack>(
      voiceSettingsControllerProvider.select((s) => s.holdMusicTrack),
      (_, track) => unawaited(_player.setTrack(track)),
      fireImmediately: true,
    );
    _evaluate();
  }

  final Ref _ref;
  final HoldMusicPlayer _player;
  final Duration _grace;
  Timer? _pending;
  bool _playing = false;

  /// Skips the grace for a person who just asked for music, if it is due at all.
  void startNow() => _evaluate(immediate: true);

  void _evaluate({bool immediate = false}) {
    final want = shouldPlayHoldMusic(
      _ref.read(voiceControllerProvider),
      _ref.read(voiceSettingsControllerProvider),
    );
    if (!want) {
      _pending?.cancel();
      _pending = null;
      if (_playing) {
        _playing = false;
        unawaited(_player.stop());
      }
      return;
    }
    if (_playing) return;
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
