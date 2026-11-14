// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Plays one soundboard clip from memory, under the same "never take the
/// call's audio" configuration every other interface sound uses.
///
/// Each clip gets its own short-lived player so clips from two people overlap
/// the way two voices do, instead of the second cutting the first off.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/voice/providers/voice_controller.dart';
import 'notification_sound.dart' show AudioPlayersSoundPlayer;
import 'sound_audio_context.dart';
import 'sound_output_router.dart';

abstract class SoundClipPlayer {
  /// Plays [bytes] once at [volume], 0 to 1.
  Future<void> play(
    Uint8List bytes, {
    required String mimeType,
    required double volume,
  });
}

class AudioPlayersSoundClipPlayer implements SoundClipPlayer {
  AudioPlayersSoundClipPlayer({this.afterPlay, bool Function()? inCall})
    : inCall = inCall ?? (() => false);

  final bool Function() inCall;
  final Future<void> Function()? afterPlay;

  /// Longer than any clip the server accepts, so a player that never reports completion is still released.
  static const _release = Duration(seconds: 8);

  @override
  Future<void> play(
    Uint8List bytes, {
    required String mimeType,
    required double volume,
  }) async {
    if (callOwnsSoundSession(inCall: inCall())) return;
    final player = AudioPlayer();
    unawaited(
      player.onPlayerComplete.first
          .timeout(_release, onTimeout: () {})
          .whenComplete(player.dispose),
    );
    await playQuietly(
      () => player.play(
        BytesSource(bytes, mimeType: mimeType),
        volume: volume * AudioPlayersSoundPlayer.playbackVolume,
        ctx: soundAudioContext,
      ),
    );
    unawaited(afterPlay?.call());
  }
}

final soundClipPlayerProvider = Provider<SoundClipPlayer>(
  (ref) => AudioPlayersSoundClipPlayer(
    afterPlay: ref.read(soundOutputRouterProvider).followChosenOutput,
    inCall: () => ref.read(voiceControllerProvider).channelId != null,
  ),
);
