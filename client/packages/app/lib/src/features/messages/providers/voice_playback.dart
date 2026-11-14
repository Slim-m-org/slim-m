// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Playing voice messages: one at a time, so starting a message stops the one
/// before it. The audio engine sits behind [VoicePlayerBackend], so tests play
/// nothing through a real device.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show Attachment;
import 'package:slimm_platform/platform.dart' show isIOSHost;

import '../../../audio/sound_output_router.dart';
import '../../voice/providers/voice_controller.dart';
import 'attachment_bytes.dart';

/// The speeds the player cycles through.
const kVoiceSpeeds = [1.0, 1.5, 2.0];

abstract class VoicePlayerBackend {
  Stream<Duration> get positions;
  Stream<void> get completed;
  Future<void> play(Uint8List bytes, String mimeType, double speed);
  Future<void> pause();
  Future<void> resume();
  Future<void> seek(Duration position);
  Future<void> setSpeed(double speed);
  Future<void> stop();
  Future<void> dispose();
}

/// `audioplayers`, built on first use because on Linux creating a player
/// aborts the app where GStreamer is missing.
class AudioPlayersVoiceBackend implements VoicePlayerBackend {
  AudioPlayersVoiceBackend({this.afterPlay});

  final Future<void> Function()? afterPlay;

  AudioPlayer? _created;
  AudioPlayer get _player => _created ??= AudioPlayer();

  @override
  Stream<Duration> get positions => _player.onPositionChanged;

  @override
  Stream<void> get completed => _player.onPlayerComplete;

  @override
  Future<void> play(Uint8List bytes, String mimeType, double speed) async {
    await _player.stop();
    await _player.setPlaybackRate(speed);
    await _player.play(BytesSource(bytes, mimeType: mimeType));
    unawaited(afterPlay?.call());
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> resume() => _player.resume();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setSpeed(double speed) => _player.setPlaybackRate(speed);

  @override
  Future<void> stop() async => _created?.stop();

  @override
  Future<void> dispose() async => _created?.dispose();
}

class VoicePlaybackState {
  const VoicePlaybackState({
    this.attachmentId,
    this.loading = false,
    this.playing = false,
    this.position = Duration.zero,
    this.speed = 1.0,
    this.error,
  });

  /// The message the engine holds, playing or paused.
  final String? attachmentId;
  final bool loading;
  final bool playing;
  final Duration position;
  final double speed;
  final String? error;

  VoicePlaybackState copyWith({
    bool? loading,
    bool? playing,
    Duration? position,
    double? speed,
  }) => VoicePlaybackState(
    attachmentId: attachmentId,
    loading: loading ?? this.loading,
    playing: playing ?? this.playing,
    position: position ?? this.position,
    speed: speed ?? this.speed,
  );
}

class VoicePlayback extends Notifier<VoicePlaybackState> {
  VoicePlayerBackend? _backend;
  StreamSubscription<Duration>? _positions;
  StreamSubscription<void>? _done;

  @override
  VoicePlaybackState build() {
    ref.onDispose(() {
      unawaited(_positions?.cancel());
      unawaited(_done?.cancel());
      unawaited(_backend?.dispose());
    });
    return const VoicePlaybackState();
  }

  VoicePlayerBackend get _engine {
    final created = _backend;
    if (created != null) return created;
    final backend = ref.read(voicePlayerFactoryProvider)();
    _positions = backend.positions.listen((position) {
      if (state.playing) state = state.copyWith(position: position);
    });
    _done = backend.completed.listen(
      (_) => state = VoicePlaybackState(speed: state.speed),
    );
    return _backend = backend;
  }

  /// Plays [voice], or pauses it, or resumes it where it stopped.
  Future<void> toggle(Attachment voice) async {
    if (state.attachmentId == voice.id && !state.loading) {
      if (state.playing) {
        await _engine.pause();
        state = state.copyWith(playing: false);
      } else {
        await _engine.resume();
        state = state.copyWith(playing: true);
      }
      return;
    }
    await _start(voice);
  }

  Future<void> _start(Attachment voice) async {
    // On iOS a call holds the shared audio session, which playback would take.
    if (isIOSHost && ref.read(voiceControllerProvider).channelId != null) {
      state = VoicePlaybackState(
        speed: state.speed,
        error: 'Leave the call to play a voice message.',
      );
      return;
    }
    state = VoicePlaybackState(
      attachmentId: voice.id,
      loading: true,
      speed: state.speed,
    );
    try {
      final bytes = await ref.read(attachmentBytesProvider(voice.id).future);
      if (state.attachmentId != voice.id) return;
      await _engine.play(bytes, voice.contentType, state.speed);
      if (state.attachmentId != voice.id) return;
      state = state.copyWith(loading: false, playing: true);
    } on Object {
      if (state.attachmentId != voice.id) return;
      state = VoicePlaybackState(
        speed: state.speed,
        error: 'The voice message could not be played.',
      );
    }
  }

  Future<void> seekTo(Attachment voice, Duration position) async {
    if (state.attachmentId != voice.id || state.loading) return;
    await _engine.seek(position);
    state = state.copyWith(position: position);
  }

  /// 1x, 1.5x, 2x, back to 1x; the engine follows if something is playing.
  Future<void> cycleSpeed() async {
    final next =
        kVoiceSpeeds[(kVoiceSpeeds.indexOf(state.speed) + 1) %
            kVoiceSpeeds.length];
    state = state.copyWith(speed: next);
    if (state.attachmentId != null && !state.loading) {
      await _engine.setSpeed(next);
    }
  }
}

final voicePlaybackProvider =
    NotifierProvider<VoicePlayback, VoicePlaybackState>(VoicePlayback.new);

/// Replaced in tests.
final voicePlayerFactoryProvider = Provider<VoicePlayerBackend Function()>(
  (ref) =>
      () => AudioPlayersVoiceBackend(
        afterPlay: ref.read(soundOutputRouterProvider).followChosenOutput,
      ),
);
