// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Steam link routes, the sharing switch, and the Steam fields on an
/// activity, at the HTTP and JSON boundary (decision 0115).
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_test_support/slimm_test_support.dart';
import 'package:test/test.dart';

const _steamLink = {
  'provider': 'steam',
  'username': 'Ada on Steam',
  'display_name': null,
  'linked_at': 1700000000000,
  'share_activity': true,
};

SlimmApi _api(List<http.Request> seen, http.Response Function(http.Request) r) {
  return testApi(
    (request) async {
      seen.add(request);
      return r(request);
    },
    session: SessionStore(
      tokens: const TokenPair(
        userId: 'user-1',
        accessToken: 'access',
        refreshToken: 'refresh',
        accessExpiresAt: 0,
      ),
    ),
  );
}

http.Response _json(Object body) => http.Response(
      jsonEncode(body),
      200,
      headers: {'content-type': 'application/json'},
    );

void main() {
  test('a Steam link reads its sharing switch, and absent means off', () {
    final link = LinkedAccount.fromJson(_steamLink);
    expect(link.isSteam, isTrue);
    expect(link.isDiscord, isFalse);
    expect(link.shareActivity, isTrue);
    final bare =
        LinkedAccount.fromJson({..._steamLink}..remove('share_activity'));
    expect(bare.shareActivity, isFalse);
  });

  test('startSteamLink answers the url and a 501 is NotConfigured', () async {
    final seen = <http.Request>[];
    final api =
        _api(seen, (_) => _json({'url': 'https://steamcommunity.com/x'}));
    expect(await api.startSteamLink(), 'https://steamcommunity.com/x');
    expect(seen.single.url.path, '/me/links/steam/start');
    final off = _api([], (_) => http.Response('{"error":"off"}', 501));
    expect(off.startSteamLink(), throwsA(isA<NotConfiguredException>()));
  });

  test('completeSteamLink posts the code and answers the account', () async {
    final seen = <http.Request>[];
    final api = _api(seen, (_) => _json(_steamLink));
    final linked = await api.completeSteamLink('ABCDE-FGHJK');
    expect(linked.provider, 'steam');
    expect(seen.single.url.path, '/me/links/steam/complete');
    expect(jsonDecode(seen.single.body), {'code': 'ABCDE-FGHJK'});
    final refused = _api([], (_) => http.Response('{"error":"no"}', 404));
    expect(refused.completeSteamLink('x'), throwsA(isA<NotFoundException>()));
  });

  test('unlinkSteam and setSteamSharing use their routes', () async {
    final seen = <http.Request>[];
    final api = _api(seen, (_) => http.Response('', 204));
    await api.unlinkSteam();
    await api.setSteamSharing(enabled: true);
    expect(seen[0].method, 'DELETE');
    expect(seen[0].url.path, '/me/links/steam');
    expect(seen[1].method, 'PUT');
    expect(seen[1].url.path, '/me/links/steam/sharing');
    expect(jsonDecode(seen[1].body), {'enabled': true});
  });

  group('activity', () {
    const art =
        'https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/730/header.jpg';

    Map<String, dynamic> game([Map<String, dynamic> extra = const {}]) => {
          'type': 'playing',
          'title': 'Counter-Strike 2',
          'source': 'steam',
          'steam_app_id': 730,
          'art_url': art,
          ...extra,
        };

    test('a game carries its app id and Steam art', () {
      final activity = PresenceActivity.tryFromJson(game())!;
      expect(activity.steamAppId, 730);
      expect(activity.artUrl, art);
      expect(activity.toJson().containsKey('steam_app_id'), isFalse);
    });

    test('art off a Steam CDN host is not drawn', () {
      for (final bad in [
        'http://cdn.steamstatic.com/a.jpg',
        'https://evilsteamstatic.com/a.jpg',
        'https://cdn.steamstatic.com.evil.example/a.jpg',
        'https://cdn.steamstatic.com:444/a.jpg',
        'https://cdn.steamstatic.com/a.jpg?t=1',
        'https://u@cdn.steamstatic.com/a.jpg',
        'https://cdn.steamstatic.com/../a.jpg',
      ]) {
        expect(
          PresenceActivity.tryFromJson(game({'art_url': bad}))!.artUrl,
          isNull,
          reason: bad,
        );
      }
    });

    test('a missing or odd app id reads as none', () {
      expect(
        PresenceActivity.tryFromJson(game({'steam_app_id': 0}))!.steamAppId,
        isNull,
      );
      expect(
        PresenceActivity.tryFromJson(game({'steam_app_id': 'x'}))!.steamAppId,
        isNull,
      );
    });
  });
}
