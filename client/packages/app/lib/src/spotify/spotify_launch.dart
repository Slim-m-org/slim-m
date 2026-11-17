// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Opens Spotify links in the installed Spotify app where there is one, and
/// in the browser otherwise.
///
/// Spotify's own SDKs hand back a code that needs a client secret on a token
/// swap server, which breaks our PKCE-only flow. Instead a phone offers the
/// https link to a non-browser handler first (a verified app link on Android,
/// a universal link on iOS), and a desktop opens a `spotify:` URI when the
/// Spotify desktop app has registered that scheme.
library;

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag, SpotifyEntity;

typedef SpotifyUrlOpener = Future<bool> Function(Uri uri, LaunchMode mode);

/// Whether some installed app claims [uri]; [canLaunchUrl] in the app.
typedef SpotifyHandlerCheck = Future<bool> Function(Uri uri);

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
  if ((phone ?? _isPhone) && await _tryApp(uri, open)) return true;
  return open(uri, LaunchMode.externalApplication);
}

/// Opens [item] in Spotify: on a phone through its app link, on a desktop
/// with the Spotify app through `spotify:`, and in the browser otherwise.
/// [canOpen] is asked only on a desktop; web never asks, since a browser
/// answers yes for any scheme.
Future<bool> openInSpotify(
  SpotifyEntity item, {
  SpotifyUrlOpener? opener,
  SpotifyHandlerCheck? canOpen,
  bool? phone,
}) async {
  final open = opener ?? _systemOpener;
  if (phone ?? _isPhone) {
    if (await _tryApp(item.webUrl, open)) return true;
  } else if (!kIsWeb &&
      await _claimed(item.appUri, canOpen ?? canLaunchUrl) &&
      await _tryOpen(item.appUri, LaunchMode.externalApplication, open)) {
    return true;
  }
  return open(item.webUrl, LaunchMode.externalApplication);
}

Future<bool> _tryApp(Uri uri, SpotifyUrlOpener open) =>
    _tryOpen(uri, LaunchMode.externalNonBrowserApplication, open);

Future<bool> _tryOpen(Uri uri, LaunchMode mode, SpotifyUrlOpener open) async {
  try {
    return await open(uri, mode);
  } on Object catch (error, stack) {
    AppLog.swallowed(
      LogTag.ui,
      'No app handled the Spotify link; using the browser',
      error,
      stack,
    );
    return false;
  }
}

Future<bool> _claimed(Uri uri, SpotifyHandlerCheck canOpen) async {
  try {
    return await canOpen(uri);
  } on Object catch (error, stack) {
    AppLog.swallowed(
      LogTag.ui,
      'Could not ask whether Spotify is installed',
      error,
      stack,
    );
    return false;
  }
}
