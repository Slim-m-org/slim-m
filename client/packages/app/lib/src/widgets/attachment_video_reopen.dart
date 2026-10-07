// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reopens a native video with the current access token when playback starts
/// after the token it was opened with rotated.
///
/// libmpv keeps sending the one header it was given for every later range
/// request, so a video left paused past the access token's lifetime would
/// otherwise 401 on its next read and stall without raising an error.
library;

import 'dart:async';

import 'package:media_kit/media_kit.dart';
import 'package:slimm_api/api.dart' as api;

import 'attachment_video_source.dart';

class StaleTokenReopener {
  StaleTokenReopener({
    required this.player,
    required this.source,
    required this.apiClient,
    required this.attachment,
    required this.onFailure,
  });

  final Player player;
  final AttachmentVideoSource source;
  final api.SlimmApi apiClient;
  final api.Attachment attachment;
  final void Function() onFailure;

  StreamSubscription<bool>? _playing;
  bool _reopening = false;

  void start() {
    _playing = player.stream.playing.listen((playing) {
      if (playing && !_reopening && source.isStale(apiClient)) {
        unawaited(_reopen());
      }
    });
  }

  Future<void> _reopen() async {
    _reopening = true;
    try {
      final position = player.state.position;
      final media = await source.open(
        apiClient: apiClient,
        attachment: attachment,
        onProgress: (_) {},
      );
      await player.open(
        Media(media.uri, httpHeaders: media.httpHeaders, start: position),
      );
    } catch (_) {
      onFailure();
    } finally {
      _reopening = false;
    }
  }

  Future<void> dispose() async => _playing?.cancel();
}
