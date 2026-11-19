// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// YouTube's rules for an embedded player, applied app-wide: one player
/// plays at a time, and none plays once the app leaves the screen (a
/// background player is forbidden by YouTube's developer policies).
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/app_lifecycle.dart';
import 'embedded_video_player.dart';

class VideoPlaybackCoordinator {
  final _players =
      <EmbeddedVideoPlayer, StreamSubscription<VideoPlayerEvent>>{};

  /// Tracks [player] until [detach]: when it starts playing, every other
  /// tracked player pauses.
  void attach(EmbeddedVideoPlayer player) {
    if (_players.containsKey(player)) return;
    _players[player] = player.events.listen((event) {
      if (event is VideoPlaying) _pauseAllBut(player);
    });
  }

  void detach(EmbeddedVideoPlayer player) =>
      unawaited(_players.remove(player)?.cancel());

  void pauseAll() => _pauseAllBut(null);

  void _pauseAllBut(EmbeddedVideoPlayer? keep) {
    for (final player in _players.keys) {
      if (!identical(player, keep)) unawaited(player.pause());
    }
  }

  void dispose() {
    for (final sub in _players.values) {
      unawaited(sub.cancel());
    }
    _players.clear();
  }
}

final videoPlaybackCoordinatorProvider = Provider<VideoPlaybackCoordinator>((
  ref,
) {
  final coordinator = VideoPlaybackCoordinator();
  ref.listen(appLifecycleProvider, (_, state) {
    if (!isWindowVisible(state)) coordinator.pauseAll();
  });
  ref.onDispose(coordinator.dispose);
  return coordinator;
});
