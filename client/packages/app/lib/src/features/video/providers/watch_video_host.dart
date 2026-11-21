// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where a YouTube watch party plays on this device: the player the sync
/// drives and, unless it lives in the desktop panel, the view the call stage
/// shows. Each host is one of the in-app players decision 0128 built, so the
/// party follows YouTube's rules the same way a tapped link does.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show LinkPreview, LinkPreviewVideoProvider;

import 'desktop_video.dart';
import 'embedded_video_player.dart';
import 'inline_video_player.dart';
import 'video_host_capability.dart';
import 'youtube_iframe_player.dart';
import 'youtube_webview_player.dart' show ShowFullscreen;

/// The watch page of [videoId], for the browser and the panel's own link.
String youtubeWatchUrl(String videoId) =>
    'https://www.youtube.com/watch?v=${Uri.encodeQueryComponent(videoId)}';

class WatchVideoHandle {
  const WatchVideoHandle({
    required this.player,
    required this.load,
    required this.release,
    this.view,
  });

  final EmbeddedVideoPlayer player;

  /// The picture for the call stage; null for the desktop's shared player,
  /// which the stage draws itself.
  final Widget? view;

  /// Replaces the video.
  final Future<void> Function(String videoId, Duration start, String title)
  load;
  final Future<void> Function() release;
}

typedef WatchVideoFactory =
    WatchVideoHandle Function(
      ProviderContainer container, {
      required String videoId,
      required Duration start,
      required String title,
      required ShowFullscreen onShowFullscreen,
      required void Function() onHideFullscreen,
    });

/// The factory for [kind], or null where nothing in the app can play YouTube.
final watchVideoFactoryProvider =
    Provider.family<WatchVideoFactory?, VideoHostKind>(
      (_, kind) => switch (kind) {
        VideoHostKind.inline when kIsWeb => _iframe,
        VideoHostKind.inline => _phone,
        VideoHostKind.desktop => _desktop,
        VideoHostKind.external => null,
      },
    );

WatchVideoHandle _iframe(
  ProviderContainer container, {
  required String videoId,
  required Duration start,
  required String title,
  required ShowFullscreen onShowFullscreen,
  required void Function() onHideFullscreen,
}) {
  final player = IframeYoutubePlayer();
  return _owned(player, player.view, videoId, start);
}

WatchVideoHandle _phone(
  ProviderContainer container, {
  required String videoId,
  required Duration start,
  required String title,
  required ShowFullscreen onShowFullscreen,
  required void Function() onHideFullscreen,
}) {
  final handle = container.read(inlineVideoFactoryProvider)(
    onShowFullscreen: onShowFullscreen,
    onHideFullscreen: onHideFullscreen,
  );
  return _owned(handle.player, handle.view, videoId, start);
}

WatchVideoHandle _owned(
  EmbeddedVideoPlayer player,
  Widget view,
  String videoId,
  Duration start,
) {
  unawaited(player.load(videoId, start: start));
  return WatchVideoHandle(
    player: player,
    view: view,
    load: (id, at, _) => player.load(id, start: at),
    release: player.dispose,
  );
}

LinkPreview _preview(String videoId, Duration start, String title) =>
    LinkPreview(
      url: youtubeWatchUrl(videoId),
      title: title,
      videoProvider: LinkPreviewVideoProvider.youtube,
      videoId: videoId,
      videoStartMs: start.inMilliseconds,
    );

/// The desktop's one shared player, shown on the call stage: a party video
/// replaces whatever was playing, and is closed when the stage lets go.
WatchVideoHandle _desktop(
  ProviderContainer container, {
  required String videoId,
  required Duration start,
  required String title,
  required ShowFullscreen onShowFullscreen,
  required void Function() onHideFullscreen,
}) {
  final desktop = container.read(desktopVideoProvider.notifier);
  final stage = Object();
  var current = youtubeWatchUrl(videoId);
  desktop.playIn(stage, current, _preview(videoId, start, title));
  final player = desktop.player!;
  return WatchVideoHandle(
    player: player,
    load: (id, at, name) async {
      current = youtubeWatchUrl(id);
      desktop.playIn(stage, current, _preview(id, at, name));
    },
    release: () async {
      if (identical(container.read(desktopVideoProvider)?.owner, stage)) {
        desktop.close();
      }
    },
  );
}
