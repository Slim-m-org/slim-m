// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Local-only looping music for a call you are alone in, from the bundled
/// tracks in [LoungeTrack]. It goes to this device's own player and is never
/// published to the room.
library;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'lounge_tracks.dart';
import 'releasable_player.dart';
import 'notification_sound.dart' show AudioPlayersSoundPlayer;

abstract class HoldMusicPlayer {
  Future<void> start();
  Future<void> stop();

  /// Switches to [track], live when it is already playing.
  Future<void> setTrack(LoungeTrack track);
  Future<void> dispose();
}

/// Quieter than a chime: this runs for minutes, not a moment.
const holdMusicVolume = 0.2;

/// The sink a track plays through, so a test can stand in for the plugin.
abstract class HoldLoopOutput {
  Future<void> play(String asset);
  Future<void> stop();
  Future<void> dispose();
}

class _AudioPlayersOutput implements HoldLoopOutput {
  /// Built on first use and disposed on every stop, so an idle app holds no native player.
  final _player = ReleasablePlayer<AudioPlayer>(
    AudioPlayer.new,
    (player) => player.dispose(),
  );

  @override
  Future<void> play(String asset) async {
    final player = _player.current;
    await player.stop();
    await player.setReleaseMode(ReleaseMode.loop);
    await player.play(
      AssetSource(asset),
      volume: holdMusicVolume,
      ctx: AudioPlayersSoundPlayer.sharedAmbientContext,
    );
  }

  @override
  Future<void> stop() => _player.release();

  @override
  Future<void> dispose() => _player.release();
}

class AudioPlayersHoldMusicPlayer implements HoldMusicPlayer {
  AudioPlayersHoldMusicPlayer({HoldLoopOutput? output})
    : _output = output ?? _AudioPlayersOutput();

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

final holdMusicPlayerProvider = Provider<HoldMusicPlayer>((ref) {
  final player = AudioPlayersHoldMusicPlayer();
  ref.onDispose(player.dispose);
  return player;
});
