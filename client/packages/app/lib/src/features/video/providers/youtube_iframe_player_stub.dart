// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Never built off the web; `watch_video_host.dart` picks a native host there.
library;

import 'package:flutter/widgets.dart';

import 'embedded_video_player.dart';

class IframeYoutubePlayer implements EmbeddedVideoPlayer {
  IframeYoutubePlayer() {
    throw UnsupportedError('the iframe player exists only on the web');
  }

  Widget get view => throw UnsupportedError('web only');

  @override
  Stream<VideoPlayerEvent> get events => throw UnsupportedError('web only');

  @override
  Future<void> load(String videoId, {Duration start = Duration.zero}) =>
      throw UnsupportedError('web only');

  @override
  Future<void> play() => throw UnsupportedError('web only');

  @override
  Future<void> pause() => throw UnsupportedError('web only');

  @override
  Future<void> seekTo(Duration position) => throw UnsupportedError('web only');

  @override
  Future<Duration> position() => throw UnsupportedError('web only');

  @override
  Future<void> dispose() => throw UnsupportedError('web only');
}
