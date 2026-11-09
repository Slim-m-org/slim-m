// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One video's native playback: the player, its render context, its media
/// source and the token reopener.
///
/// The inline row and any fullscreen route showing the video each hold a
/// share, and whoever lets go last disposes it, so a row unmounting under an
/// open fullscreen route cannot kill the picture still being watched.
library;

import 'dart:async';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:slimm_api/api.dart' as api;

import 'attachment_video_reopen.dart';
import 'attachment_video_source.dart';

class AttachmentPlayback {
  AttachmentPlayback({
    required this.player,
    required this.source,
    required api.SlimmApi apiClient,
    required api.Attachment attachment,
    required VideoController Function() createController,
    required void Function() onPlaybackError,
  }) : _createController = createController,
       _reopener = StaleTokenReopener(
         player: player,
         source: source,
         apiClient: apiClient,
         attachment: attachment,
         onFailure: onPlaybackError,
       ) {
    // A decode failure mid-playback surfaces here rather than a thrown Future, since it can fire after open() already succeeded.
    _errorSub = player.stream.error.listen((_) {
      if (!_reopener.reopenIfStale()) onPlaybackError();
    });
    _reopener.start();
  }

  final Player player;
  final AttachmentVideoSource source;
  final VideoController Function() _createController;
  final StaleTokenReopener _reopener;
  late final StreamSubscription<String> _errorSub;
  int _holders = 1;

  late final VideoController controller = _createController();

  /// Opens [media] paused; the render context comes first because mpv picks its video output when a file opens, so without one the file plays as audio over black.
  Future<void> openPaused(Media media) {
    controller;
    return player.open(media, play: false);
  }

  /// Takes a share in the playback; every call needs a matching [release].
  void retain() {
    assert(_holders > 0, 'retained after it was disposed');
    _holders++;
  }

  void release() {
    if (--_holders > 0) return;
    unawaited(_errorSub.cancel());
    unawaited(_reopener.dispose());
    unawaited(player.dispose());
    source.dispose();
  }
}
