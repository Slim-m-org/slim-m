// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The phone player: the host page in the system webview (Android WebView,
/// iOS WKWebView) through webview_flutter, inline in the message.
library;

import 'dart:async';
import 'dart:ui' show Color;

import 'package:flutter/widgets.dart' show Widget;
import 'package:slimm_api/api.dart' show AppLog, LogTag;
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../../../external_link.dart';
import 'youtube_bridge_player.dart';
import 'youtube_host_page.dart';

/// What the player hands over when the page asks for fullscreen on Android;
/// iOS plays fullscreen in its own native player instead.
typedef ShowFullscreen = void Function(Widget view, void Function() onExit);

class WebViewYoutubePlayer extends YoutubeBridgePlayer {
  WebViewYoutubePlayer({
    required ShowFullscreen onShowFullscreen,
    required void Function() onHideFullscreen,
  }) : controller = WebViewController.fromPlatformCreationParams(
         _creationParams(),
       ) {
    unawaited(_configure(onShowFullscreen, onHideFullscreen));
  }

  final WebViewController controller;

  static PlatformWebViewControllerCreationParams _creationParams() {
    if (WebViewPlatform.instance is WebKitWebViewPlatform) {
      // Without inline playback an iPhone forces its own fullscreen on play.
      return WebKitWebViewControllerCreationParams(
        allowsInlineMediaPlayback: true,
        mediaTypesRequiringUserAction: const {},
      );
    }
    return const PlatformWebViewControllerCreationParams();
  }

  Future<void> _configure(
    ShowFullscreen onShowFullscreen,
    void Function() onHideFullscreen,
  ) async {
    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await controller.setBackgroundColor(const Color(0xFF000000));
    await controller.addJavaScriptChannel(
      kYoutubeBridgeName,
      onMessageReceived: (message) => handleMessage(message.message),
    );
    await controller.setNavigationDelegate(
      NavigationDelegate(onNavigationRequest: _onNavigation),
    );
    if (controller.platform case final AndroidWebViewController android) {
      // The tap that asked for the video happened in Flutter, not in the page.
      await android.setMediaPlaybackRequiresUserGesture(false);
      await android.setCustomWidgetCallbacks(
        onShowCustomWidget: onShowFullscreen,
        onHideCustomWidget: onHideFullscreen,
      );
    }
    await controller.loadHtmlString(
      youtubeHostHtml,
      baseUrl: '$kYoutubeHostOrigin/',
    );
  }

  /// The player's own frames load in place; anything else the page tries to
  /// open, such as the YouTube logo, goes to the system browser.
  NavigationDecision _onNavigation(NavigationRequest request) {
    if (!request.isMainFrame || isYoutubeHostNavigation(request.url)) {
      return NavigationDecision.navigate;
    }
    unawaited(openExternalHttpUrl(request.url));
    return NavigationDecision.prevent;
  }

  @override
  Future<void> runScript(String script) => controller.runJavaScript(script);

  /// Blanks the page so nothing keeps playing; the view may already be gone.
  @override
  Future<void> disposeHost() async {
    try {
      await controller.loadRequest(Uri.parse('about:blank'));
    } on Object catch (error, stack) {
      AppLog.swallowed(
        LogTag.media,
        'The player view went first',
        error,
        stack,
      );
    }
  }
}

/// Whether a top-level navigation is the host page itself loading.
bool isYoutubeHostNavigation(String url) =>
    url.startsWith(kYoutubeHostOrigin) ||
    url.startsWith('about:') ||
    url.startsWith('data:');
