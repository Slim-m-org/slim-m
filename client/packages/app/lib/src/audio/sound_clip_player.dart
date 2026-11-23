// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Plays one soundboard clip from memory. Outside a call it uses the same
/// "never take the call's audio" configuration every other interface sound
/// uses; on iPhone in a call it goes to the app's own engine in the call's session.
///
/// Each clip gets its own short-lived player so clips from two people overlap
/// the way two voices do, instead of the second cutting the first off.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'call_holds_audio_session.dart';
import 'call_path_clip_output.dart';
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
  AudioPlayersSoundClipPlayer({
    this.afterPlay,
    bool Function()? inCall,
    this.ios,
    SoundClipPlayer? callPath,
  }) : inCall = inCall ?? (() => false),
       _callPath = callPath ?? CallPathSoundClipPlayer();

  final bool Function() inCall;
  final bool? ios;
  final SoundClipPlayer _callPath;
  final Future<void> Function()? afterPlay;

  /// Longer than any clip the server accepts, so a player that never reports completion is still released.
  static const _release = Duration(seconds: 8);

  @override
  Future<void> play(
    Uint8List bytes, {
    required String mimeType,
    required double volume,
  }) async {
    if (callOwnsSoundSession(inCall: inCall(), ios: ios)) {
      return _playInCall(bytes, mimeType: mimeType, volume: volume);
    }
    final player = AudioPlayer();
    // onPlayerComplete is a Stream<AudioEvent> at runtime, so its first must be retyped before timeout takes a void fallback.
    final completed = player.onPlayerComplete.first.then<void>(
      (_) {},
      onError: (Object _) {},
    );
    unawaited(
      completed
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

  /// The call holds the iOS session, so the clip joins it rather than taking it.
  Future<void> _playInCall(
    Uint8List bytes, {
    required String mimeType,
    required double volume,
  }) => _callPath.play(
    bytes,
    mimeType: mimeType,
    volume: volume * AudioPlayersSoundPlayer.playbackVolume,
  );
}

final soundClipPlayerProvider = Provider<SoundClipPlayer>(
  (ref) => AudioPlayersSoundClipPlayer(
    afterPlay: ref.read(soundOutputRouterProvider).followChosenOutput,
    inCall: ref.read(callHoldsAudioSessionProvider),
  ),
);
