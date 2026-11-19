// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The video playing in the desktop panel, if any. It belongs to the shell,
/// not to a message, so it plays on while the reader scrolls away or
/// switches channel, until they close it.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show LinkPreview;

import 'docked_video_player.dart';
import 'native_video_host.dart';
import 'video_host_capability.dart';
import 'video_playback_coordinator.dart';

class DockedVideo {
  const DockedVideo({
    required this.url,
    required this.videoId,
    this.start = Duration.zero,
    this.title,
    this.author,
  });

  /// The pasted link, which is also how a card knows it is the one playing.
  final String url;
  final String videoId;
  final Duration start;
  final String? title;
  final String? author;
}

final dockedVideoPlayerFactoryProvider = Provider<DockedVideoPlayer Function()>(
  (ref) =>
      () => NativeDockedPlayer(ref.read(nativeVideoHostProvider)),
);

class DockedVideoController extends Notifier<DockedVideo?> {
  DockedVideoPlayer? _player;

  /// Held from the attach on, since the release can run while the container is disposing.
  VideoPlaybackCoordinator? _coordinator;

  /// The panel's player while a video is docked.
  DockedVideoPlayer? get player => _player;

  @override
  DockedVideo? build() {
    ref.onDispose(() => unawaited(_release()));
    return null;
  }

  /// Plays [preview]'s video in the panel, replacing whatever played there.
  void open(String url, LinkPreview preview) {
    final id = preview.videoId;
    if (!preview.isPlayableVideo || id == null) return;
    final player = _player ??= _attach(
      ref.read(dockedVideoPlayerFactoryProvider)(),
    );
    unawaited(player.load(id, start: preview.videoStart));
    state = DockedVideo(
      url: url,
      videoId: id,
      start: preview.videoStart,
      title: preview.title,
      author: preview.authorName,
    );
  }

  void close() {
    state = null;
    unawaited(_release());
  }

  DockedVideoPlayer _attach(DockedVideoPlayer player) {
    final VideoPlaybackCoordinator coordinator =
        _coordinator ?? ref.read(videoPlaybackCoordinatorProvider);
    _coordinator = coordinator;
    coordinator.attach(player);
    return player;
  }

  Future<void> _release() async {
    final player = _player;
    _player = null;
    if (player == null) return;
    _coordinator?.detach(player);
    await player.dispose();
  }
}

final dockedVideoProvider =
    NotifierProvider<DockedVideoController, DockedVideo?>(
      DockedVideoController.new,
    );
