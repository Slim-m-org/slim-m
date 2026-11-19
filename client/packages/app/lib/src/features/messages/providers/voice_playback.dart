// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Playing voice messages: one at a time, so starting a message stops the one
/// before it. The audio engine sits behind [VoicePlayerBackend], so tests play
/// nothing through a real device.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show Attachment, AppLog, LogTag;
import 'package:slimm_platform/platform.dart' show isIOSHost;

import '../../../audio/call_holds_audio_session.dart';
import '../../../audio/call_start_yields.dart';
import '../../../audio/sound_output_router.dart';
import '../../accounts/providers/account_slot.dart';
import '../../voice/providers/voice_flags.dart';
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
  /// [player] stands in for the engine in tests.
  AudioPlayersVoiceBackend({this.afterPlay, AudioPlayer Function()? player})
    : _create = player ?? AudioPlayer.new;

  final Future<void> Function()? afterPlay;
  final AudioPlayer Function() _create;

  AudioPlayer? _created;
  AudioPlayer get _player => _created ??= _create();

  @override
  Stream<Duration> get positions => _player.onPositionChanged;

  @override
  Stream<void> get completed => _player.onPlayerComplete;

  @override
  Future<void> play(Uint8List bytes, String mimeType, double speed) async {
    await _player.stop();
    await _player.play(BytesSource(bytes, mimeType: mimeType));
    // Opening a clip resets the rate in the browser and in GStreamer, so it is set once the clip plays.
    await _player.setPlaybackRate(speed);
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

/// Why a message did not play.
enum VoicePlaybackError {
  /// The clip could not be fetched or decoded; trying again may work.
  unplayable,

  /// On iOS a call holds the audio session playback would take.
  inCall,
}

class VoicePlaybackState {
  const VoicePlaybackState({
    this.attachmentId,
    this.loading = false,
    this.playing = false,
    this.position = Duration.zero,
    this.speed = 1.0,
    this.error,
    this.errorFor,
  });

  /// The message the engine holds, playing or paused.
  final String? attachmentId;
  final bool loading;
  final bool playing;
  final Duration position;
  final double speed;
  final VoicePlaybackError? error;

  /// The message [error] is about, so only its player shows it.
  final String? errorFor;

  /// Leaves [error] behind: it belongs to the moment it was set.
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
  /// [ios] stands in for the host in tests.
  VoicePlayback({bool? ios}) : _ios = ios ?? isIOSHost;

  final bool _ios;
  VoicePlayerBackend? _backend;
  StreamSubscription<Duration>? _positions;
  StreamSubscription<void>? _done;

  @override
  VoicePlaybackState build() {
    if (_ios) {
      ref.listen(voiceFlagsProvider.select((f) => f.channelId), (_, channel) {
        if (channel == null && state.error == VoicePlaybackError.inCall) {
          dismissError();
        }
      });
    }
    // The yields are shared by every community, so a call joined in another one pauses this message too.
    ref.onDispose(ref.read(callStartYieldsProvider).add(_pauseForCall));
    ref.listen(accountActiveProvider, (_, onScreen) {
      if (!onScreen) unawaited(_pauseForCall());
    });
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
    _done = backend.completed.listen((_) {
      // A clip already stopped for another one can still report its end.
      if (state.playing) state = VoicePlaybackState(speed: state.speed);
    });
    return _backend = backend;
  }

  /// Plays [voice], or pauses it, or resumes it where it stopped.
  Future<void> toggle(Attachment voice) async {
    if (state.attachmentId == voice.id && !state.loading) {
      if (state.playing) {
        await _engine.pause();
        state = state.copyWith(playing: false);
      } else if (!_refusedInCall(voice)) {
        await _engine.resume();
        state = state.copyWith(playing: true);
      }
      return;
    }
    await _start(voice);
  }

  /// A call starting pauses a message where it is, so Play resumes it.
  Future<void> _pauseForCall() async {
    if (state.loading) {
      // Nothing holds the message now, so its play stops as it lands.
      state = VoicePlaybackState(speed: state.speed);
      return;
    }
    if (!state.playing) return;
    await _engine.pause();
    state = state.copyWith(playing: false);
  }

  void dismissError() => state = state.copyWith();

  // On iOS a call holds the shared audio session, which playback would take.
  bool _refusedInCall(Attachment voice) {
    if (!_ios || !ref.read(callHoldsAudioSessionProvider)()) return false;
    // A paused message keeps its place for after the call; one still loading lets go, so its play stops as it lands.
    final held = state.loading ? null : state.attachmentId;
    state = VoicePlaybackState(
      attachmentId: held,
      playing: state.playing,
      position: state.position,
      speed: state.speed,
      error: VoicePlaybackError.inCall,
      errorFor: voice.id,
    );
    return true;
  }

  Future<void> _start(Attachment voice) async {
    if (_refusedInCall(voice)) return;
    final previous = state.attachmentId;
    state = VoicePlaybackState(
      attachmentId: voice.id,
      loading: true,
      speed: state.speed,
    );
    // The clip that was chosen before stops now, not once this one has downloaded.
    if (previous != null) await _backend?.stop();
    try {
      final bytes = await ref.read(attachmentBytesProvider(voice.id).future);
      if (state.attachmentId != voice.id) return;
      final speed = state.speed;
      await _engine.play(bytes, voice.contentType, speed);
      if (state.attachmentId != voice.id) {
        // Nothing holds this message any more, so a play that landed late must not keep sounding.
        if (state.attachmentId == null) await _engine.stop();
        return;
      }
      state = state.copyWith(loading: false, playing: true);
      // A speed chosen while the clip was opening skipped the engine.
      if (state.speed != speed) await _engine.setSpeed(state.speed);
    } on Object catch (error, stack) {
      AppLog.swallowed(
        LogTag.voice,
        'A voice message could not play',
        error,
        stack,
      );
      if (state.attachmentId != voice.id) return;
      state = VoicePlaybackState(
        speed: state.speed,
        error: VoicePlaybackError.unplayable,
        errorFor: voice.id,
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
