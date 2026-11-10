// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Receiving Spotify's redirect (decision 0056).
///
/// The OS hands `slimm://spotify-callback` to the deep-link stream, which
/// [handleSpotifyCallback] answers, and to Flutter's own route information,
/// which `CallbackRouteGuard` keeps away from the router.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
import '../routing/router.dart';
import '../routing/routes.dart';
import 'spotify_link.dart';

bool isSpotifyCallback(Uri uri) =>
    uri.scheme == 'slimm' && uri.host == 'spotify-callback';

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
