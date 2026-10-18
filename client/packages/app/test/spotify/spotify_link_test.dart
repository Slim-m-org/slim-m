// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Spotify link from switch to result: the browser step stays off until
/// the redirect is exchanged, every way the redirect can end says so in
/// [spotifyLinkStatusProvider], and a redirect that outlives the process
/// still finishes (decision 0056). Spotify through the real publisher stays
/// off by default and silent while hidden.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/deep_links.dart';
import 'package:slimm_app/src/features/members/providers/activity_feeds.dart';
import 'package:slimm_app/src/features/members/providers/presence_controller.dart';
import 'package:slimm_app/src/spotify/spotify_client.dart';
import 'package:slimm_app/src/spotify/spotify_link.dart';
import 'package:slimm_app/src/spotify/spotify_source.dart';
import 'package:slimm_app/src/spotify/spotify_link_status.dart';

import 'spotify_rig.dart';

SpotifyLinkStatus _status(SpotifyRig rig) =>
    rig.container.read(spotifyLinkStatusProvider);

String _failure(SpotifyRig rig) => (_status(rig) as SpotifyFailed).message;

/// Turns the switch on, leaving the browser step open and the redirect to the test.
Future<void> _begin(SpotifyRig rig) async {
  await rig.container.read(shareSpotifyProvider.notifier).connect();
  await rig.settle();
}

void main() {
  test('the feature is absent from a build with no client id', () async {
    final rig = SpotifyRig(clientId: '');
    addTearDown(rig.dispose);
    await rig.start();
    expect(rig.container.read(availableActivityFeedsProvider), isEmpty);
    await rig.linker.begin();
    expect(rig.launched, isEmpty);
  });

  test('it is off by default and makes no Spotify request', () async {
    final rig = SpotifyRig();
    addTearDown(rig.dispose);
    await rig.start();
    expect(rig.container.read(shareSpotifyProvider), isFalse);
    expect(_status(rig), isA<SpotifyUnlinked>());
    expect(rig.spotify, isEmpty);
    expect(rig.calls, isEmpty);
  });

  test('turning it on opens Spotify and waits, still off', () async {
    final rig = SpotifyRig();
    addTearDown(rig.dispose);
    await rig.start();
    await _begin(rig);

    expect(rig.launched.single.host, 'accounts.spotify.com');
    expect(rig.launched.single.queryParameters['client_id'], 'client-id');
    expect(_status(rig), isA<SpotifyWaiting>());
    expect(rig.container.read(shareSpotifyProvider), isFalse);
    expect(
      await rig.container.read(spotifyTokenStoreProvider).loadPending(),
      isNotNull,
    );
  });

  test('the redirect links it, names the account and turns it on', () async {
    final rig = SpotifyRig();
    addTearDown(rig.dispose);
    await rig.start();
    await _begin(rig);

    expect(await rig.linker.handleCallback(rig.redirect()), isTrue);

    expect(_status(rig), isA<SpotifyConnected>());
    expect((_status(rig) as SpotifyConnected).text, 'Connected as Nick');
    expect(rig.container.read(shareSpotifyProvider), isTrue);
    final store = rig.container.read(spotifyTokenStoreProvider);
    expect((await store.load())?.accessToken, 'a');
    expect(await store.loadPending(), isNull);
    await rig.settle();
    expect(rig.calls, contains('PUT /presence/activity'));
  });

  test('a profile Spotify will not give still links, without a name', () async {
    final rig = SpotifyRig();
    addTearDown(rig.dispose);
    rig.profile = () => http.Response('', 403);
    await rig.start();
    await _begin(rig);
    await rig.linker.handleCallback(rig.redirect());
    expect((_status(rig) as SpotifyConnected).text, 'Connected to Spotify');
    expect(rig.container.read(shareSpotifyProvider), isTrue);
  });

  test('a restart shows who is connected', () async {
    final first = SpotifyRig();
    await first.start();
    await _begin(first);
    await first.linker.handleCallback(first.redirect());
    final again = SpotifyRig(keys: first.keys);
    addTearDown(again.dispose);
    addTearDown(first.dispose);
    again.container.read(spotifyLinkStatusProvider);
    await again.settle();
    expect((_status(again) as SpotifyConnected).text, 'Connected as Nick');
  });

  test('a redirect after the app was killed still finishes the link', () async {
    final first = SpotifyRig();
    await first.start();
    await _begin(first);
    final redirect = first.redirect();
    first.container.dispose();

    final cold = SpotifyRig(keys: first.keys);
    addTearDown(cold.dispose);
    addTearDown(first.links.close);
    await cold.start();
    expect(await cold.linker.handleCallback(redirect), isTrue);
    expect(cold.container.read(shareSpotifyProvider), isTrue);
    expect(_status(cold), isA<SpotifyConnected>());
  });

  group('every way the redirect can end says so', () {
    Future<SpotifyRig> waiting() async {
      final rig = SpotifyRig();
      addTearDown(rig.dispose);
      await rig.start();
      await _begin(rig);
      return rig;
    }

    Future<void> expectNothingLinked(SpotifyRig rig) async {
      expect(rig.container.read(shareSpotifyProvider), isFalse);
      final store = rig.container.read(spotifyTokenStoreProvider);
      expect(await store.load(), isNull);
      expect(await store.loadPending(), isNull);
    }

    test('declined consent', () async {
      final rig = await waiting();
      await rig.linker.handleCallback(
        rig.redirect(code: null, error: 'access_denied'),
      );
      expect(_failure(rig), contains('declined'));
      expect(_failure(rig), isNot(contains('access_denied')));
      await expectNothingLinked(rig);
    });

    test('a state that is not ours', () async {
      final rig = await waiting();
      await rig.linker.handleCallback(rig.redirect(state: 'forged'));
      expect(_failure(rig), contains('did not match'));
      await expectNothingLinked(rig);
    });

    test('no code', () async {
      final rig = await waiting();
      await rig.linker.handleCallback(rig.redirect(code: null));
      expect(_failure(rig), contains('code'));
      await expectNothingLinked(rig);
    });

    test('an attempt older than the timeout', () async {
      final rig = SpotifyRig(linkTimeout: const Duration(milliseconds: 20));
      addTearDown(rig.dispose);
      await rig.start();
      await _begin(rig);
      final redirect = rig.redirect();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await rig.linker.handleCallback(redirect);
      expect(_failure(rig), contains('expired'));
      await expectNothingLinked(rig);
    });

    test('a browser that never comes back times out in place', () async {
      final rig = SpotifyRig(linkTimeout: const Duration(milliseconds: 20));
      addTearDown(rig.dispose);
      await rig.start();
      await _begin(rig);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(_failure(rig), contains('timed out'));
      await expectNothingLinked(rig);
    });

    test('a redirect nobody asked for, while unlinked', () async {
      final rig = SpotifyRig();
      addTearDown(rig.dispose);
      await rig.start();
      await rig.linker.handleCallback(
        Uri.parse('slimm://spotify-callback?code=c&state=s'),
      );
      expect(_failure(rig), contains('expired'));
      await expectNothingLinked(rig);
    });

    test('a redirect nobody asked for, while already linked', () async {
      final rig = await waiting();
      await rig.linker.handleCallback(rig.redirect());
      await rig.linker.handleCallback(
        Uri.parse('slimm://spotify-callback?code=c&state=s'),
      );
      expect(_status(rig), isA<SpotifyConnected>());
      expect(rig.container.read(shareSpotifyProvider), isTrue);
    });

    test('Spotify refusing the code', () async {
      final rig = await waiting();
      rig.token = () => http.Response('{"error":"invalid_grant"}', 400);
      await rig.linker.handleCallback(rig.redirect());
      expect(_failure(rig), contains('spotify refused'));
      await expectNothingLinked(rig);
    });

    test('a reply that is not JSON, or lacks a field', () async {
      for (final body in [
        '<html>',
        '{"access_token":"a","refresh_token":"r"}',
      ]) {
        final rig = await waiting();
        rig.token = () => http.Response(body, 200);
        await rig.linker.handleCallback(rig.redirect());
        expect(_failure(rig), contains('could not read'), reason: body);
        await expectNothingLinked(rig);
      }
    });

    test('the network failing', () async {
      final rig = await waiting();
      rig.token = () => throw http.ClientException('offline');
      await rig.linker.handleCallback(rig.redirect());
      expect(_failure(rig), contains('Could not reach Spotify'));
      await expectNothingLinked(rig);
    });
  });

  test('a browser that will not open is reported and leaves it off', () async {
    final rig = SpotifyRig(launches: false);
    addTearDown(rig.dispose);
    await rig.start();
    await _begin(rig);
    expect(rig.container.read(shareSpotifyProvider), isFalse);
    expect(_failure(rig), contains('browser'));
    expect(
      await rig.container.read(spotifyTokenStoreProvider).loadPending(),
      isNull,
    );
  });

  test('retry after a failure starts a fresh attempt', () async {
    final rig = SpotifyRig();
    addTearDown(rig.dispose);
    await rig.start();
    await _begin(rig);
    await rig.linker.handleCallback(rig.redirect(state: 'forged'));
    expect(_status(rig), isA<SpotifyFailed>());

    await _begin(rig);
    expect(rig.launched, hasLength(2));
    expect(_status(rig), isA<SpotifyWaiting>());
    await rig.linker.handleCallback(rig.redirect());
    expect(_status(rig), isA<SpotifyConnected>());
  });

  test('cancelling the wait forgets the attempt', () async {
    final rig = SpotifyRig();
    addTearDown(rig.dispose);
    await rig.start();
    await _begin(rig);
    final late = rig.redirect();
    await rig.linker.cancel();
    expect(_status(rig), isA<SpotifyUnlinked>());
    await rig.linker.handleCallback(late);
    expect(_failure(rig), contains('expired'));
    expect(rig.container.read(shareSpotifyProvider), isFalse);
  });

  test('dismissing an error returns to what is true without it', () async {
    final rig = SpotifyRig();
    addTearDown(rig.dispose);
    await rig.start();
    await _begin(rig);
    await rig.linker.handleCallback(rig.redirect(state: 'forged'));
    await rig.linker.dismissFailure();
    expect(_status(rig), isA<SpotifyUnlinked>());
  });

  test('turning it off deletes the link and clears the activity', () async {
    final rig = SpotifyRig();
    addTearDown(rig.dispose);
    await rig.start();
    await _begin(rig);
    await rig.linker.handleCallback(rig.redirect());
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(rig.calls, contains('PUT /presence/activity'));

    await rig.container.read(shareSpotifyProvider.notifier).disconnect();
    await rig.settle();
    final store = rig.container.read(spotifyTokenStoreProvider);
    expect(await store.load(), isNull);
    expect(await store.loadAccount(), isNull);
    expect(_status(rig), isA<SpotifyUnlinked>());
    expect(rig.calls.last, 'DELETE /presence/activity');
  });

  test('a grant Spotify withdrew switches it off and says so', () async {
    final rig = SpotifyRig();
    addTearDown(rig.dispose);
    await rig.start();
    await _begin(rig);
    await rig.linker.handleCallback(rig.redirect());
    await rig.container
        .read(spotifyTokenStoreProvider)
        .save(
          SpotifyTokens(
            accessToken: 'a',
            refreshToken: 'r',
            expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
          ),
        );
    rig.token = () =>
        http.Response(jsonEncode({'error': 'invalid_grant'}), 400);
    await SpotifyNowPlayingSource(
      client: rig.container.read(spotifyClientProvider),
      store: rig.container.read(spotifyTokenStoreProvider),
      onRevoked: () => rig.container.read(spotifyLinkerProvider).revoked(),
    ).watch().first.timeout(const Duration(seconds: 2), onTimeout: () => null);
    await rig.settle();

    expect(rig.container.read(shareSpotifyProvider), isFalse);
    expect(_failure(rig), contains('no longer lets'));
  });

  test('hidden makes no Spotify request and sends nothing', () async {
    final rig = SpotifyRig();
    addTearDown(rig.dispose);
    await rig.container
        .read(spotifyTokenStoreProvider)
        .save(
          SpotifyTokens(
            accessToken: 'a',
            refreshToken: 'r',
            expiresAt: DateTime.now().add(const Duration(hours: 1)),
          ),
        );
    rig.container.read(presenceVisibilityDisplayProvider.notifier).state =
        api.PresenceVisibility.hidden;
    await rig.start(enabled: true);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(rig.spotify, isEmpty);
    expect(rig.calls, isEmpty);
  });

  test('linked with the show-track switch off publishes nothing', () async {
    final rig = SpotifyRig();
    addTearDown(rig.dispose);
    await rig.start();
    await _begin(rig);
    await rig.linker.handleCallback(rig.redirect());
    await rig.settle();
    expect(rig.calls, contains('PUT /presence/activity'));

    await rig.container.read(shareSpotifyProvider.notifier).setEnabled(false);
    await rig.settle();
    expect(_status(rig), isA<SpotifyConnected>(), reason: 'still linked');
    rig.calls.clear();
    rig.spotify.clear();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(rig.calls.where((c) => c.startsWith('PUT')), isEmpty);
    expect(rig.spotify, isEmpty);
  });

  test('a linked device sends the track while visible', () async {
    final rig = SpotifyRig();
    addTearDown(rig.dispose);
    await rig.container
        .read(spotifyTokenStoreProvider)
        .save(
          SpotifyTokens(
            accessToken: 'a',
            refreshToken: 'r',
            expiresAt: DateTime.now().add(const Duration(hours: 1)),
          ),
        );
    await rig.start(enabled: true);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(rig.calls, ['PUT /presence/activity']);
  });

  test('the redirect is ignored by the invite and message handlers', () {
    final uri = Uri.parse('slimm://spotify-callback?code=c&state=s');
    expect(inviteFromDeepLink(uri, signedIn: false), isNull);
    expect(
      messageFromDeepLink(uri, signedInTo: Uri.parse('https://x.test')),
      isNull,
    );
  });
}
