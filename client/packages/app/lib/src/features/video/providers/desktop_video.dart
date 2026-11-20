// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The video the desktop's one player shows, and where. It plays in place in
/// the message that was tapped; when that message leaves the screen (a
/// scroll, a channel switch) while it plays, it moves to the panel beside
/// the chat and plays on there until closed. A paused video just closes.
/// Its fullscreen hold lives here too, so a move never drops the window out.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show LinkPreview;

import '../../../desktop/desktop_window_port.dart';
import '../../../desktop/desktop_window_shell.dart';
import '../../../desktop/window_fullscreen_hold.dart';
import '../../voice/providers/fullscreen_video.dart';
import 'desktop_video_player.dart';
import 'embedded_video_player.dart';
import 'native_video_host.dart';
import 'video_host_capability.dart';
import 'video_playback_coordinator.dart';

class DesktopVideo {
  const DesktopVideo({
    required this.url,
    required this.videoId,
    this.start = Duration.zero,
    this.title,
    this.author,
    this.owner,
  });

  /// The pasted link, which is also how a card knows it is the one playing.
  final String url;
  final String videoId;
  final Duration start;
  final String? title;
  final String? author;

  /// The message card showing the video in place; null once it plays on in
  /// the panel.
  final Object? owner;

  bool get docked => owner == null;

  DesktopVideo placedIn(Object? owner) => DesktopVideo(
    url: url,
    videoId: videoId,
    start: start,
    title: title,
    author: author,
    owner: owner,
  );
}

final desktopVideoPlayerFactoryProvider =
    Provider<DesktopVideoPlayer Function()>(
      (ref) =>
          () => TextureVideoPlayer(ref.read(nativeVideoHostProvider)),
    );

class DesktopVideoController extends Notifier<DesktopVideo?> {
  DesktopVideoPlayer? _player;

  /// Held from the attach on, since the release can run while the container is disposing.
  VideoPlaybackCoordinator? _coordinator;
  WindowFullscreenHold? _fullscreenHold;
  StreamSubscription<VideoPlayerEvent>? _events;
  StreamSubscription<DesktopWindowEventKind>? _windowLeaves;
  bool _playing = false;
  bool _disposed = false;
  final _views = <Object>[];
  final _front = ValueNotifier<Object?>(null);
  final _fullscreen = ValueNotifier<bool>(false);

  /// The player while a video is loaded.
  DesktopVideoPlayer? get player => _player;

  /// The view that sizes the page: the one shown most recently.
  ValueListenable<Object?> get frontView => _front;

  /// Whether the page is fullscreen, so the front view covers the window.
  ValueListenable<bool> get fullscreen => _fullscreen;

  @override
  DesktopVideo? build() {
    ref.onDispose(() {
      _disposed = true;
      unawaited(_release());
    });
    return null;
  }

  /// Plays [preview]'s video in place in [owner]'s message. The video
  /// already loaded moves there as it is, without starting over.
  void playIn(Object owner, String url, LinkPreview preview) {
    final id = preview.videoId;
    if (!preview.isPlayableVideo || id == null) return;
    final current = state;
    if (current != null && current.url == url && _player != null) {
      state = current.placedIn(owner);
      return;
    }
    final player = _player ??= _attach(
      ref.read(desktopVideoPlayerFactoryProvider)(),
    );
    // Asked to autoplay, so a message that leaves before the first frame still hands it on.
    _playing = true;
    unawaited(player.load(id, start: preview.videoStart));
    state = DesktopVideo(
      url: url,
      videoId: id,
      start: preview.videoStart,
      title: preview.title,
      author: preview.authorName,
      owner: owner,
    );
  }

  /// [owner]'s message left the screen: a playing video plays on in the
  /// panel, anything else closes.
  void leave(Object owner) {
    if (_disposed) return;
    final current = state;
    if (current == null || !identical(current.owner, owner)) return;
    if (_playing) {
      state = current.placedIn(null);
    } else {
      close();
    }
  }

  /// The message showing the video scrolled out of sight while it stays
  /// mounted (a list keeps a margin of rows built): the same as it leaving.
  void scrolledAway() {
    final owner = state?.owner;
    if (owner != null) leave(owner);
  }

  void close() {
    state = null;
    unawaited(_release());
  }

  /// A view starts showing the texture; the newest sizes the page.
  void showIn(Object view) {
    _views
      ..remove(view)
      ..add(view);
    _front.value = view;
  }

  /// A view stops showing it. With none left after this frame the video
  /// pauses, since nothing plays where it cannot be seen.
  void hideFrom(Object view) {
    if (!_views.remove(view)) return;
    _front.value = _views.isEmpty ? null : _views.last;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (_views.isEmpty) unawaited(_player?.pause());
    });
  }

  DesktopVideoPlayer _attach(DesktopVideoPlayer player) {
    final VideoPlaybackCoordinator coordinator =
        _coordinator ?? ref.read(videoPlaybackCoordinatorProvider);
    _coordinator = coordinator;
    coordinator.attach(player);
    final shell = ref.read(desktopWindowShellProvider);
    final hold = _fullscreenHold ??= WindowFullscreenHold(
      ref.read(fullscreenVideoActiveProvider.notifier),
      shell,
    );
    _events = player.events.listen((event) {
      switch (event) {
        case VideoPlaying() || VideoBuffering():
          _playing = true;
        case VideoPaused() || VideoEnded() || VideoFailed():
          _playing = false;
        case VideoFullscreenChanged(:final on):
          _fullscreen.value = on;
          on ? unawaited(hold.enter()) : hold.release();
        case VideoReady():
          break;
      }
    });
    // Leaving window fullscreen first (Esc, the window manager) takes the page out too.
    _windowLeaves = shell.port.events
        .where((kind) => kind == DesktopWindowEventKind.leaveFullScreen)
        .listen((_) => unawaited(player.exitFullscreen()));
    return player;
  }

  Future<void> _release() async {
    final player = _player;
    _player = null;
    _playing = false;
    _fullscreen.value = false;
    if (player == null) return;
    unawaited(_events?.cancel());
    unawaited(_windowLeaves?.cancel());
    _events = null;
    _windowLeaves = null;
    _fullscreenHold?.release();
    _coordinator?.detach(player);
    await player.dispose();
  }
}

final desktopVideoProvider =
    NotifierProvider<DesktopVideoController, DesktopVideo?>(
      DesktopVideoController.new,
    );
