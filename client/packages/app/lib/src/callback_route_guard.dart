// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keeps a callback link out of the router.
///
/// The OS hands `slimm://spotify-callback` and `slimm://discord-link` (and `steam-link`) to two
/// places: the deep-link stream, which finishes the link, and Flutter's own
/// route information, which go_router read as `/` and used to replace the
/// open Settings modal with the channel list. [CallbackRouteGuard] answers the
/// second so the router never sees it.
library;

import 'package:flutter/widgets.dart';

import 'discord_link_callback.dart';
import 'spotify/spotify_callback.dart';

/// It has to be registered before the router's own observer, which is why the
/// deep-link controller adds it at startup.
class CallbackRouteGuard with WidgetsBindingObserver {
  @override
  Future<bool> didPushRouteInformation(
    RouteInformation routeInformation,
  ) async {
    final uri = routeInformation.uri;
    return isSpotifyCallback(uri) ||
        isDiscordLinkDelivery(uri) ||
        isSteamLinkDelivery(uri);
  }
}
