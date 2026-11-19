// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How a message builds its own in-place player on a phone: the player to
/// drive and the view that shows it. A provider so a test can swap in a fake.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'embedded_video_player.dart';
import 'youtube_webview_player.dart';

typedef InlineVideoHandle = ({EmbeddedVideoPlayer player, Widget view});

typedef InlineVideoFactory =
    InlineVideoHandle Function({
      required ShowFullscreen onShowFullscreen,
      required void Function() onHideFullscreen,
    });

final inlineVideoFactoryProvider = Provider<InlineVideoFactory>(
  (ref) => _webViewHandle,
);

/// Taps and the seek bar's drag reach the player; a vertical drag still
/// scrolls the conversation it sits in.
const _playerGestures = <Factory<OneSequenceGestureRecognizer>>{
  Factory<TapGestureRecognizer>(TapGestureRecognizer.new),
  Factory<HorizontalDragGestureRecognizer>(HorizontalDragGestureRecognizer.new),
};

InlineVideoHandle _webViewHandle({
  required ShowFullscreen onShowFullscreen,
  required void Function() onHideFullscreen,
}) {
  final player = WebViewYoutubePlayer(
    onShowFullscreen: onShowFullscreen,
    onHideFullscreen: onHideFullscreen,
  );
  final platform = player.controller.platform;
  final view = platform is AndroidWebViewController
      // Hybrid composition, since video under a texture layer can draw black.
      ? WebViewWidget.fromPlatformCreationParams(
          params: AndroidWebViewWidgetCreationParams(
            controller: platform,
            displayWithHybridComposition: true,
            gestureRecognizers: _playerGestures,
          ),
        )
      : WebViewWidget(
          controller: player.controller,
          gestureRecognizers: _playerGestures,
        );
  return (player: player, view: view);
}
