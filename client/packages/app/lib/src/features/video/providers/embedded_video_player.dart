// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one surface every in-app video player offers, whatever hosts it: a
/// phone's webview, a desktop's native panel, or a test fake. A later
/// watch-together layer drives players through this alone.
library;

/// What a player reports as it runs.
sealed class VideoPlayerEvent {
  const VideoPlayerEvent();
}

/// The player is loaded and accepts commands.
final class VideoReady extends VideoPlayerEvent {
  const VideoReady();
}

final class VideoPlaying extends VideoPlayerEvent {
  const VideoPlaying();
}

final class VideoPaused extends VideoPlayerEvent {
  const VideoPaused();
}

final class VideoBuffering extends VideoPlayerEvent {
  const VideoBuffering();
}

final class VideoEnded extends VideoPlayerEvent {
  const VideoEnded();
}

/// The player could not play: [code] is YouTube's own error number (2 bad
/// id, 5 player error, 100 not found, 101/150 embedding refused, 152/153
/// referrer refused), or -1 when the player itself could not be loaded.
final class VideoFailed extends VideoPlayerEvent {
  const VideoFailed(this.code);

  final int code;

  /// Whether the video's owner turned embedding off, so only the site plays it.
  bool get embeddingRefused => code == 101 || code == 150;
}

/// The page entered or left fullscreen; the host's window should follow.
final class VideoFullscreenChanged extends VideoPlayerEvent {
  const VideoFullscreenChanged({required this.on});

  final bool on;
}

abstract interface class EmbeddedVideoPlayer {
  Stream<VideoPlayerEvent> get events;

  /// Starts [videoId] at [start], replacing whatever was loaded.
  Future<void> load(String videoId, {Duration start = Duration.zero});

  Future<void> play();

  Future<void> pause();

  Future<void> seekTo(Duration position);

  /// The playback position as the player last reported it.
  Future<Duration> position();

  Future<void> dispose();
}
