// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Receiving Spotify's redirect (decision 0056).
///
/// The OS hands `slimm://spotify-callback` to two places: the deep-link
/// stream, which finishes the link, and Flutter's own route information,
/// which go_router read as `/` and used to replace the open Settings modal
/// with the channel list. [SpotifyRouteGuard] answers the second so the
/// router never sees it, and [handleSpotifyCallback] is the first.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
import '../routing/router.dart';
import '../routing/routes.dart';
import 'spotify_link.dart';

bool isSpotifyCallback(Uri uri) =>
    uri.scheme == 'slimm' && uri.host == 'spotify-callback';

/// Claims the redirect before the router can navigate on it. It has to be
/// registered before the router's own observer, which is why the deep-link
/// controller adds it at startup.
class SpotifyRouteGuard with WidgetsBindingObserver {
  @override
  Future<bool> didPushRouteInformation(
    RouteInformation routeInformation,
  ) async => isSpotifyCallback(routeInformation.uri);
}

/// Finishes the link, then makes sure the result is on screen: a redirect
/// that arrives with Settings closed (a cold start) opens the Profile pane,
/// where the Spotify row says what happened.
Future<void> handleSpotifyCallback(ProviderContainer container, Uri uri) async {
  await container.read(spotifyLinkerProvider).handleCallback(uri);
  if (!container.read(sessionProvider).isSignedIn) return;
  final router = container.read(routerProvider);
  final open = router.state.uri.path;
  if (open == Routes.personalSettings) return;
  await router.push(Routes.personalSettingsPane('profile'));
}
