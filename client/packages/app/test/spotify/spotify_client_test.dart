// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// PKCE and the three Spotify calls, against a fake HTTP client.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_app/src/spotify/spotify_client.dart';
import 'package:slimm_app/src/spotify/spotify_config.dart';
import 'package:slimm_app/src/spotify/spotify_pkce.dart';

final _now = DateTime.utc(2026, 9, 30, 12);

SpotifyClient _client(
  Future<http.Response> Function(http.Request) handler, {
  List<http.Request>? seen,
}) => SpotifyClient(
  client: MockClient((request) {
    seen?.add(request);
    return handler(request);
  }),
  clientId: 'client-id',
  now: () => _now,
);

String _track({
  bool playing = true,
  String type = 'track',
  List<String> artists = const ['A', 'B'],
  List<Map<String, Object>> images = const [
    {'url': 'https://example.invalid/cover.jpg'},
  ],
}) => jsonEncode({
  'is_playing': playing,
  'currently_playing_type': type,
  'item': {
    'name': ' Song ',
    'artists': [
      for (final name in artists) {'name': name},
    ],
    'album': {'images': images},
  },
});

void main() {
  group('pkce', () {
    test('the challenge matches the RFC 7636 example', () async {
      expect(
        await codeChallenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
        'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
      );
    });

    test('verifier and state are long, unreserved and never repeat', () {
      final a = randomUrlSafe();
      final b = randomUrlSafe();
      expect(a, hasLength(64));
      expect(a, matches(RegExp(r'^[A-Za-z0-9\-._~]+$')));
      expect(a, isNot(b));
    });

    test('the authorize url asks for one scope and carries no secret', () {
      final uri = spotifyAuthorizeUri(
        clientId: 'client-id',
        challenge: 'chal',
        state: 'st',
      );
      expect(uri.host, 'accounts.spotify.com');
      expect(uri.queryParameters['scope'], 'user-read-currently-playing');
      expect(uri.queryParameters['code_challenge_method'], 'S256');
      expect(uri.queryParameters['redirect_uri'], spotifyRedirectUri);
      expect(uri.queryParameters.containsKey('client_secret'), isFalse);
    });
  });

  group('tokens', () {
    test('a code exchange sends the verifier and no secret', () async {
      final seen = <http.Request>[];
      final client = _client(
        (_) async => http.Response(
          jsonEncode({
            'access_token': 'a',
            'refresh_token': 'r',
            'expires_in': 3600,
          }),
          200,
        ),
        seen: seen,
      );
      final tokens = await client.exchangeCode('code', 'verifier');
      expect(tokens.accessToken, 'a');
      expect(tokens.expiresAt, _now.add(const Duration(hours: 1)));
      expect(seen.single.bodyFields, {
        'grant_type': 'authorization_code',
        'code': 'code',
        'redirect_uri': spotifyRedirectUri,
        'code_verifier': 'verifier',
        'client_id': 'client-id',
      });
    });

    test(
      'a refresh that returns no new refresh token keeps the old one',
      () async {
        final client = _client(
          (_) async => http.Response(
            jsonEncode({'access_token': 'a2', 'expires_in': 60}),
            200,
          ),
        );
        expect((await client.refresh('old')).refreshToken, 'old');
      },
    );

    test('a refused grant is an auth failure, a 500 is not', () async {
      await expectLater(
        _client((_) async => http.Response('{}', 400)).refresh('r'),
        throwsA(isA<SpotifyAuthException>()),
      );
      await expectLater(
        _client((_) async => http.Response('', 503)).refresh('r'),
        throwsA(isA<http.ClientException>()),
      );
    });

    test('tokens round-trip through json', () {
      final tokens = SpotifyTokens(
        accessToken: 'a',
        refreshToken: 'r',
        expiresAt: _now,
      );
      final back = SpotifyTokens.fromJson(tokens.toJson());
      expect(back.refreshToken, 'r');
      expect(back.expiresAt.isAtSameMomentAs(_now), isTrue);
      expect(tokens.expiresWithin(const Duration(minutes: 1), _now), isTrue);
    });
  });

  group('currently playing', () {
    Future<SpotifyPlayback> read(http.Response response) =>
        _client((_) async => response).currentlyPlaying('token');

    test('a playing track gives title and joined artists', () async {
      final playback = await read(http.Response(_track(), 200));
      expect(playback, isA<SpotifyPlaying>());
      playback as SpotifyPlaying;
      expect(playback.title, 'Song');
      expect(playback.artist, 'A, B');
    });

    test('the position and track length come through', () async {
      final playback = await read(
        http.Response(
          '{"is_playing":true,"currently_playing_type":"track","progress_ms":'
          '1234,"item":{"name":"Song","duration_ms":200000,"artists":[]}}',
          200,
        ),
      );
      playback as SpotifyPlaying;
      expect(playback.positionMs, 1234);
      expect(playback.durationMs, 200000);
    });

    const base = 'https://i.scdn.co/image/ab67616d0000';
    const ids = {640: 'b273', 300: '1e02', 64: '4851'};
    Map<String, Object> image(int size) => {
      'url': '$base${ids[size]}bc2dd68b840b1d4b7c9e5ad9',
      'width': size,
    };

    test('the cover is the smallest image that still draws sharp', () async {
      final playback = await read(
        http.Response(_track(images: [image(640), image(300), image(64)]), 200),
      );
      expect((playback as SpotifyPlaying).artUrl, image(300)['url']);
    });

    test('a cover off the Spotify CDN is never taken', () async {
      final playback = await read(http.Response(_track(), 200));
      expect((playback as SpotifyPlaying).artUrl, isNull);
    });

    test('paused, an episode, an ad and nothing are all idle', () async {
      expect(
        await read(http.Response(_track(playing: false), 200)),
        isA<SpotifyIdle>(),
      );
      expect(
        await read(http.Response(_track(type: 'episode'), 200)),
        isA<SpotifyIdle>(),
      );
      expect(
        await read(http.Response(_track(type: 'ad'), 200)),
        isA<SpotifyIdle>(),
      );
      expect(await read(http.Response('', 204)), isA<SpotifyIdle>());
    });

    test('an expired token and a rate limit are told apart', () async {
      expect(await read(http.Response('', 401)), isA<SpotifyUnauthorized>());
      final limited = await read(
        http.Response('', 429, headers: {'retry-after': '7'}),
      );
      expect(
        (limited as SpotifyRateLimited).retryAfter,
        const Duration(seconds: 7),
      );
    });

    test(
      'the token goes in the header and nothing else is requested',
      () async {
        final seen = <http.Request>[];
        await _client(
          (_) async => http.Response('', 204),
          seen: seen,
        ).currentlyPlaying('token');
        expect(seen.single.headers['Authorization'], 'Bearer token');
        expect(seen.single.url.path, '/v1/me/player/currently-playing');
      },
    );
  });
}
