// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Plays a clip when the server says someone in this call played it.
///
/// The decision to stay silent is all here: not in that call, deafened, the
/// "Soundboard sounds" switch off, or the player silenced for this listener.
/// The player's own per-person volume scales the clip.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_rtc/rtc.dart' show perceptualParticipantGain;

import '../../../audio/sound_clip_player.dart';
import '../../../providers/live_events.dart';
import 'soundboard_clips.dart';
import 'soundboard_settings.dart';
import 'voice_controller.dart';

class SoundboardPlayer {
  SoundboardPlayer(this._ref) {
    final sub = _ref.read(liveEventsProvider).listen(_onEvent);
    _ref.onDispose(() => unawaited(sub.cancel()));
  }

  final Ref _ref;

  void _onEvent(api.ServerEvent event) {
    if (event is! api.SoundboardPlayed) return;
    final voice = _ref.read(voiceControllerProvider);
    if (voice.channelId != event.channelId || voice.deafened) return;
    if (!_ref.read(soundboardSoundsProvider)) return;
    final controller = _ref.read(voiceControllerProvider.notifier);
    if (controller.isLocallyMuted(event.playerId)) return;
    final volume = perceptualParticipantGain(
      controller.volumes.volumeFor(event.playerId),
    );
    unawaited(_play(event.clipId, volume.clamp(0.0, 1.0)));
  }

  Future<void> _play(String clipId, double volume) async {
    try {
      final audio = await _ref.read(soundClipAudioProvider(clipId).future);
      await _ref
          .read(soundClipPlayerProvider)
          .play(audio.bytes, mimeType: audio.contentType, volume: volume);
    } on Object catch (error, stack) {
      api.AppLog.swallowed(
        api.LogTag.voice,
        'A soundboard clip could not play',
        error,
        stack,
      );
    }
  }
}

/// Watched from the account services so it lives for the session.
final soundboardPlayerProvider = Provider<SoundboardPlayer>(
  SoundboardPlayer.new,
);
