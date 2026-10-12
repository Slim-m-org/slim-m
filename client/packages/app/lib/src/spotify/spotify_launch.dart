// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Opens Spotify's consent page, preferring the installed Spotify app.
///
/// Spotify's own SDKs hand back a code that needs a client secret on a token
/// swap server, which breaks our PKCE-only flow. Instead the authorize URL is
/// offered to a non-browser handler first (a verified app link on Android, a
/// universal link on iOS), and falls back to the browser when none claims it.
library;

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

typedef SpotifyUrlOpener = Future<bool> Function(Uri uri, LaunchMode mode);

Future<bool> _systemOpener(Uri uri, LaunchMode mode) =>
    launchUrl(uri, mode: mode);

/// Phones try the app path first; desktop and web go straight to the browser.
bool get _isPhone =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

Future<bool> openSpotifyAuthorize(
  Uri uri, {
  SpotifyUrlOpener? opener,
  bool? phone,
}) async {
  final open = opener ?? _systemOpener;
  if (phone ?? _isPhone) {
    try {
      if (await open(uri, LaunchMode.externalNonBrowserApplication)) {
        return true;
      }
    } on Object {
      // No app claimed the link; the browser below still works.
    }
  }
  return open(uri, LaunchMode.externalApplication);
}
