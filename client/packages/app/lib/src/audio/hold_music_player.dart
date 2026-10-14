// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Local-only looping music for a call you are alone in, from the bundled
/// tracks in [LoungeTrack]. It goes to this device's own player and is never
/// published to the room.
library;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'lounge_tracks.dart';
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
  /// Built on first use, so a session that never plays music never touches the audio plugin.
  AudioPlayer? _created;
  AudioPlayer get _player => _created ??= AudioPlayer();

  @override
  Future<void> play(String asset) async {
    await _player.stop();
    await _player.setReleaseMode(ReleaseMode.loop);
    await _player.play(
      AssetSource(asset),
      volume: holdMusicVolume,
      ctx: AudioPlayersSoundPlayer.sharedAmbientContext,
    );
  }

  @override
  Future<void> stop() async => _created?.stop();

  @override
  Future<void> dispose() async => _created?.dispose();
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
    await _output.play(_track.asset);
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
