// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Local-only looping music for a call you are alone in, from the bundled
/// tracks in [LoungeTrack]. It goes to this device's own player and is never
/// published to the room.
library;

import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart' show isIOSHost;

import 'lounge_tracks.dart';
import 'releasable_player.dart';
import 'sound_output_router.dart';
import 'sound_audio_context.dart';

/// Where the loop is, for the badge's timeline; [duration] is null until the file reports it.
class HoldPlayback {
  const HoldPlayback({this.position = Duration.zero, this.duration});

  static const idle = HoldPlayback();

  final Duration position;
  final Duration? duration;

  HoldPlayback copyWith({Duration? position, Duration? duration}) =>
      HoldPlayback(
        position: position ?? this.position,
        duration: duration ?? this.duration,
      );

  @override
  bool operator ==(Object other) =>
      other is HoldPlayback &&
      other.position == position &&
      other.duration == duration;

  @override
  int get hashCode => Object.hash(position, duration);
}

/// Where the loop is, for the badge's timeline; [duration] is null until the file reports it.
class HoldPlayback {
  const HoldPlayback({this.position = Duration.zero, this.duration});

  static const idle = HoldPlayback();

  final Duration position;
  final Duration? duration;

  HoldPlayback copyWith({Duration? position, Duration? duration}) =>
      HoldPlayback(
        position: position ?? this.position,
        duration: duration ?? this.duration,
      );

  @override
  bool operator ==(Object other) =>
      other is HoldPlayback &&
      other.position == position &&
      other.duration == duration;

  @override
  int get hashCode => Object.hash(position, duration);
}

abstract class HoldMusicPlayer {
  Future<void> start();
  Future<void> stop();

  /// Holds the track where it is, keeping the native player; [resume] carries on from there.
  Future<void> pause();
  Future<void> resume();

  /// The loop's progress; back at zero whenever it is stopped.
  ValueListenable<HoldPlayback> get playback;

  /// Live volume, 0 to 1.
  Future<void> setVolume(double volume);

  /// Jumps within the track that is playing; a no-op while stopped.
  Future<void> seek(Duration position);

  /// Switches to [track], live when it is already playing.
  Future<void> setTrack(LoungeTrack track);
  Future<void> dispose();
}

/// The sink a track plays through, so a test can stand in for the plugin.
abstract class HoldLoopOutput {
  Future<void> play(String asset);
  Future<void> stop();
  Future<void> pause();
  Future<void> resume();
  Future<void> dispose();
  ValueListenable<HoldPlayback> get playback;
  Future<void> setVolume(double volume);
  Future<void> seek(Duration position);
}

class _AudioPlayersOutput implements HoldLoopOutput {
  _AudioPlayersOutput(this._afterPlay);

  final Future<void> Function()? _afterPlay;
  final _playback = ValueNotifier(HoldPlayback.idle);
  final _subscriptions = <StreamSubscription<Object>>[];
  double _volume = defaultHoldMusicVolume;

  @override
  ValueListenable<HoldPlayback> get playback => _playback;

  /// Built on first use and disposed on every stop, so an idle app holds no native player.
  final _player = ReleasablePlayer<AudioPlayer>(
    AudioPlayer.new,
    (player) => player.dispose(),
  );

  @override
  Future<void> play(String asset) async {
    final player = _player.current;
    await player.stop();
    _playback.value = HoldPlayback.idle;
    _follow(player);
    await player.setReleaseMode(ReleaseMode.loop);
    await playQuietly(
      () => player.play(
        AssetSource(asset),
        volume: _volume,
        ctx: soundAudioContext,
      ),
    );
    unawaited(_afterPlay?.call());
  }

  void _follow(AudioPlayer player) {
    _unfollow();
    _subscriptions
      ..add(
        player.onPositionChanged.listen(
          (p) => _playback.value = _playback.value.copyWith(position: p),
        ),
      )
      ..add(
        player.onDurationChanged.listen(
          (d) => _playback.value = _playback.value.copyWith(duration: d),
        ),
      );
  }

  void _unfollow() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
  }

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume;
    if (_player.allocated) await _player.current.setVolume(volume);
  }

  @override
  Future<void> seek(Duration position) async {
    if (_player.allocated) await _player.current.seek(position);
  }

  @override
  Future<void> pause() async {
    if (_player.allocated) await _player.current.pause();
  }

  @override
  Future<void> resume() async {
    if (_player.allocated) await _player.current.resume();
  }

  @override
  Future<void> stop() {
    _unfollow();
    _playback.value = HoldPlayback.idle;
    return _player.release();
  }

  @override
  Future<void> dispose() {
    _unfollow();
    return _player.release();
  }
}

class AudioPlayersHoldMusicPlayer implements HoldMusicPlayer {
  AudioPlayersHoldMusicPlayer({
    HoldLoopOutput? output,
    Future<void> Function()? afterPlay,
  }) : _output = output ?? _AudioPlayersOutput(afterPlay);

  final HoldLoopOutput _output;
  LoungeTrack _track = LoungeTrack.lofi;
  bool _active = false;

  /// Bumped by every stop, so a start still opening its file can tell it lost.
  int _generation = 0;

  @override
  Future<void> start() async {
    _active = true;
    final generation = _generation;
    try {
      await _output.play(_track.asset);
    } catch (_) {
      // A stop that landed mid-start disposed the player under it.
      if (generation == _generation) rethrow;
    }
    if (generation != _generation) await _output.stop();
  }

  @override
  Future<void> stop() async {
    _active = false;
    _generation++;
    await _output.stop();
  }

  @override
  ValueListenable<HoldPlayback> get playback => _output.playback;

  @override
  Future<void> setVolume(double volume) => _output.setVolume(volume);

  @override
  Future<void> seek(Duration position) => _output.seek(position);

  @override
  Future<void> pause() => _output.pause();

  @override
  Future<void> resume() => _output.resume();

  @override
  Future<void> setTrack(LoungeTrack track) async {
    if (track == _track) return;
    _track = track;
    if (_active) await start();
  }

  @override
  Future<void> dispose() async {
    _active = false;
    _generation++;
    await _output.dispose();
  }
}

/// False on iOS: audioplayers there resets the call's own audio session category and deactivates it when the loop stops.
final holdMusicAvailableProvider = Provider<bool>((ref) => !isIOSHost);

final holdMusicPlayerProvider = Provider<HoldMusicPlayer>((ref) {
  final router = ref.read(soundOutputRouterProvider);
  final player = AudioPlayersHoldMusicPlayer(
    afterPlay: router.followChosenOutput,
  );
  ref.onDispose(player.dispose);
  return player;
});
