// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Spotify source: no request before someone listens or without a token,
/// refresh on expiry, revoked links dropped, rate limits and network blips
/// leave the last answer standing.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_app/src/spotify/spotify_client.dart';
import 'package:slimm_app/src/spotify/spotify_source.dart';
import 'package:slimm_app/src/spotify/spotify_token_store.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_platform/testing.dart';

final _now = DateTime.utc(2026, 9, 30, 12);

const _playing =
    '{"is_playing":true,"currently_playing_type":"track",'
    '"item":{"name":"Song","artists":[{"name":"A"}]}}';

class _Rig {
  _Rig() {
    store = SpotifyTokenStore(InMemoryKeyStore());
    source = SpotifyNowPlayingSource(
      client: SpotifyClient(
        client: MockClient((request) async {
          requests.add('${request.method} ${request.url.host}');
          return respond(request);
        }),
        clientId: 'id',
        now: () => _now,
      ),
      store: store,
      pollInterval: const Duration(milliseconds: 10),
      now: () => _now,
    );
  }

  late final SpotifyTokenStore store;
  late final SpotifyNowPlayingSource source;
  final requests = <String>[];
  Future<http.Response> Function(http.Request) respond = (_) async =>
      http.Response(_playing, 200);

  Future<void> signIn({Duration validFor = const Duration(hours: 1)}) =>
      store.save(
        SpotifyTokens(
          accessToken: 'access',
          refreshToken: 'refresh',
          expiresAt: _now.add(validFor),
        ),
      );
}

http.Response _refreshed() => http.Response(
  jsonEncode({
    'access_token': 'new',
    'refresh_token': 'r2',
    'expires_in': 3600,
  }),
  200,
);

void main() {
  test('nothing is requested until someone listens', () async {
    final rig = _Rig();
    await rig.signIn();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(rig.requests, isEmpty);
    expect(
      await rig.source.watch().first,
      const NowPlaying(title: 'Song', artist: 'A', source: 'Spotify'),
    );
  });

  test('an unlinked device reads as nothing and makes no request', () async {
    final rig = _Rig();
    expect(await rig.source.watch().first, isNull);
    expect(rig.requests, isEmpty);
  });

  test('an expiring token is refreshed and saved before reading', () async {
    final rig = _Rig();
    await rig.signIn(validFor: const Duration(seconds: 10));
    rig.respond = (request) async => request.url.host == 'accounts.spotify.com'
        ? _refreshed()
        : http.Response(_playing, 200);
    await rig.source.watch().first;
    expect(rig.requests.first, 'POST accounts.spotify.com');
    expect((await rig.store.load())?.accessToken, 'new');
  });

  test('a 401 refreshes once and retries', () async {
    final rig = _Rig();
    await rig.signIn();
    var played = 0;
    rig.respond = (request) async {
      if (request.url.host == 'accounts.spotify.com') return _refreshed();
      return played++ == 0
          ? http.Response('', 401)
          : http.Response(_playing, 200);
    };
    expect((await rig.source.watch().first)?.title, 'Song');
  });

  test('a revoked link drops the stored token and reads as nothing', () async {
    final rig = _Rig();
    await rig.signIn(validFor: const Duration(seconds: 1));
    rig.respond = (_) async => http.Response('{}', 400);
    expect(await rig.source.watch().first, isNull);
    expect(await rig.store.load(), isNull);
  });

  test('a rate limit keeps the last answer and pauses requests', () async {
    final rig = _Rig();
    await rig.signIn();
    var limited = false;
    rig.respond = (_) async => limited
        ? http.Response('', 429, headers: {'retry-after': '60'})
        : http.Response(_playing, 200);
    final seen = <NowPlaying?>[];
    final sub = rig.source.watch().listen(seen.add);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    limited = true;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    final afterLimit = rig.requests.length;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await sub.cancel();
    expect(seen, [
      const NowPlaying(title: 'Song', artist: 'A', source: 'Spotify'),
    ]);
    expect(rig.requests.length, afterLimit);
  });

  test('a network failure leaves the last answer standing', () async {
    final rig = _Rig();
    await rig.signIn();
    var down = false;
    rig.respond = (_) async => down
        ? throw http.ClientException('offline')
        : http.Response(_playing, 200);
    final seen = <NowPlaying?>[];
    final sub = rig.source.watch().listen(seen.add);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    down = true;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await sub.cancel();
    expect(seen, hasLength(1));
  });

  test('cancelling stops every request', () async {
    final rig = _Rig();
    await rig.signIn();
    final sub = rig.source.watch().listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await sub.cancel();
    final count = rig.requests.length;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(rig.requests.length, count);
  });
}
