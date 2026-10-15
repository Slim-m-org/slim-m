// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reopens a native video with the current access token when playback starts
/// after the token it was opened with rotated.
///
/// libmpv keeps sending the one header it was given for every later range
/// request, so a video left paused past the access token's lifetime would
/// otherwise 401 on its next read and stall without raising an error. A seek
/// or a cache refill well into playback hits the same wall, so a stall or an
/// error while the token is stale reopens too.
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

  final _subscriptions = <StreamSubscription<Object>>[];
  bool _reopening = false;

  void start() {
    _subscriptions
      ..add(
        player.stream.playing.listen((playing) {
          if (playing) reopenIfStale();
        }),
      )
      ..add(
        player.stream.buffering.listen((buffering) {
          if (buffering) reopenIfStale();
        }),
      );
  }

  /// Reopens when the open-time token has rotated; returns whether it did, so
  /// a caller seeing a playback error knows it is already being handled.
  bool reopenIfStale() {
    if (_reopening || !source.isStale(apiClient)) return false;
    unawaited(_reopen());
    return true;
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

  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
  }
}
