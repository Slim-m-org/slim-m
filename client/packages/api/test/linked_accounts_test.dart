// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The linked-accounts model and the four JSON routes, at the HTTP boundary.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

const _link = {
  'provider': 'discord',
  'username': 'nick#0',
  'display_name': 'Nick',
  'linked_at': 1700000000000,
};

SlimmApi _api(List<http.Request> seen, http.Response Function(http.Request) r) {
  return testApi((request) async {
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
      ));
}

http.Response _json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

void main() {
  test('LinkedAccount.fromJson reads every field', () {
    final link = LinkedAccount.fromJson(_link);
    expect(link.isDiscord, isTrue);
    expect(link.username, 'nick#0');
    expect(link.displayName, 'Nick');
    expect(link.linkedAt, 1700000000000);
  });

  test('a null display name stays null', () {
    final link = LinkedAccount.fromJson({..._link, 'display_name': null});
    expect(link.displayName, isNull);
  });

  test('myLinkedAccounts and linkedAccountsOf hit their routes', () async {
    final seen = <http.Request>[];
    final api = _api(seen, (_) => _json([_link]));
    expect((await api.myLinkedAccounts()).single.username, 'nick#0');
    expect((await api.linkedAccountsOf('u-2')).single.username, 'nick#0');
    expect(seen.map((r) => '${r.method} ${r.url.path}'), [
      'GET /me/links',
      'GET /users/u-2/links',
    ]);
  });

  test('startDiscordLink answers the url', () async {
    final seen = <http.Request>[];
    final api = _api(seen, (_) => _json({'url': 'https://discord.com/x'}));
    expect(await api.startDiscordLink(), 'https://discord.com/x');
    expect(seen.single.method, 'POST');
    expect(seen.single.url.path, '/me/links/discord/start');
  });

  test('a 501 start is NotConfiguredException', () async {
    final api = _api([], (_) => http.Response('', 501));
    expect(api.startDiscordLink(), throwsA(isA<NotConfiguredException>()));
  });

  test('unlinkDiscord sends DELETE and accepts 204', () async {
    final seen = <http.Request>[];
    final api = _api(seen, (_) => http.Response('', 204));
    await api.unlinkDiscord();
    expect(seen.single.method, 'DELETE');
    expect(seen.single.url.path, '/me/links/discord');
  });
}
