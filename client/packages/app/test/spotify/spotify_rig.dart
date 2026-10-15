// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A container wired like the app's with a fake Spotify: the consent page is
/// a recorded launch, the token and profile endpoints answer from [token] and
/// [profile], and presence calls are recorded.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/deep_links.dart';
import 'package:slimm_app/src/providers/activity_feeds.dart';
import 'package:slimm_app/src/providers/activity_publisher.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/spotify/spotify_client.dart';
import 'package:slimm_app/src/spotify/spotify_config.dart';
import 'package:slimm_app/src/spotify/spotify_link.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

http.Response tokenReply() => http.Response(
  jsonEncode({'access_token': 'a', 'refresh_token': 'r', 'expires_in': 3600}),
  200,
);

class SpotifyRig {
  SpotifyRig({
    String clientId = 'client-id',
    this.launches = true,
    KeyStore? keys,
    Duration linkTimeout = const Duration(minutes: 10),
  }) : keys = keys ?? InMemoryKeyStore() {
    container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(this.keys),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        liveEventsProvider.overrideWithValue(const Stream.empty()),
        nowPlayingSourceProvider.overrideWithValue(null),
        gameSourceProvider.overrideWithValue(null),
        spotifyClientIdProvider.overrideWithValue(clientId),
        spotifyLinkTimeoutProvider.overrideWithValue(linkTimeout),
        deepLinkUrisProvider.overrideWithValue(links.stream),
        spotifyLauncherProvider.overrideWithValue((uri) async {
          launched.add(uri);
          return launches;
        }),
        spotifyClientProvider.overrideWithValue(
          SpotifyClient(
            client: MockClient((request) async {
              spotify.add('${request.method} ${request.url.host}');
              if (request.url.host == 'accounts.spotify.com') return token();
              if (request.url.path == '/v1/me') return profile();
              return http.Response(
                '{"is_playing":true,"currently_playing_type":"track",'
                '"item":{"name":"Song","artists":[]}}',
                200,
              );
            }),
            clientId: clientId,
          ),
        ),
        apiProvider.overrideWith((ref) {
          final client = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient((request) async {
              if (request.url.path == '/me') {
                return http.Response(
                  '{"id":"self","username":"self","display_name":"Self",'
                  '"created_at":0,"permissions":0}',
                  200,
                  headers: {'content-type': 'application/json'},
                );
              }
              calls.add('${request.method} ${request.url.path}');
              return http.Response('', 204);
            }),
          );
          ref.onDispose(client.close);
          return client;
        }),
      ],
    );
  }

  final bool launches;
  final KeyStore keys;
  final links = StreamController<Uri>.broadcast(sync: true);
  final launched = <Uri>[];
  final spotify = <String>[];
  final calls = <String>[];
  late final ProviderContainer container;

  /// What the token endpoint and the profile call answer; swap per test.
  http.Response Function() token = tokenReply;
  http.Response Function() profile = () =>
      http.Response('{"display_name":"Nick","id":"nick1"}', 200);

  SpotifyLinker get linker => container.read(spotifyLinkerProvider);

  Future<void> start({bool enabled = false}) async {
    SharedPreferences.setMockInitialValues({
      if (enabled) shareSpotifyKey: true,
    });
    await container.read(preferencesProvider.future);
    container.read(activityPublisherProvider);
    await container.read(meProvider.future);
    await settle();
  }

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 5));

  /// The redirect Spotify sends back, carrying the state it was given.
  Uri redirect({String? state, String? code = 'the-code', String? error}) {
    final sent = launched.last.queryParameters['state'];
    return Uri(
      scheme: 'slimm',
      host: 'spotify-callback',
      queryParameters: {
        'code': ?code,
        'error': ?error,
        'state': state ?? sent!,
      },
    );
  }

  Future<void> dispose() async {
    container.dispose();
    await links.close();
  }
}
