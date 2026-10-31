// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [DirectPlayer] over `media_kit`, the player the attachment video already uses.
library;

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'direct_player.dart';

class MediaKitDirectPlayer implements DirectPlayer {
  MediaKitDirectPlayer() {
    _video = VideoController(_player);
  }

  final Player _player = Player();
  late final VideoController _video;

  @override
  Duration get position => _player.state.position;

  @override
  bool get isPlaying => _player.state.playing;

  @override
  bool get isBuffering => _player.state.buffering;

  @override
  Future<void> open(String url, Map<String, String> headers, Duration start) =>
      _player.open(Media(url, httpHeaders: headers, start: start), play: false);

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setRate(double rate) => _player.setRate(rate);

  @override
  Widget buildVideo() => Video(controller: _video, controls: null);

  @override
  Future<void> dispose() => _player.dispose();
}
