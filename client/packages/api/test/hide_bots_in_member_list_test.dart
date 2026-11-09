// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Space switch that takes bots out of the member list, as `/version` and
/// `/space/settings` report it and as the settings call writes it.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_test_support/slimm_test_support.dart';
import 'package:test/test.dart';

SlimmApi _api(Future<http.Response> Function(http.Request) handler) => testApi(
      handler,
      session: SessionStore(
        tokens: const TokenPair(
          userId: 'u1',
          accessToken: 'access',
          refreshToken: 'refresh',
          accessExpiresAt: 0,
        ),
      ),
    );

void main() {
  test('/version reads bots as listed when an older server omits the field',
      () {
    final old =
        Version.fromJson({'name': 'slim-m', 'version': '1', 'protocol': 1});
    expect(old.hideBotsInMemberList, isFalse);
    final hidden = Version.fromJson({
      'name': 'slim-m',
      'version': '1',
      'protocol': 1,
      'hide_bots_in_member_list': true,
    });
    expect(hidden.hideBotsInMemberList, isTrue);
  });

  test('space settings read the switch and default it to listed', () {
    final old = SpaceSettings.fromJson({'join_policy': 'invite'});
    expect(old.hideBotsInMemberList, isFalse);
    final hidden = SpaceSettings.fromJson({
      'join_policy': 'invite',
      'hide_bots_in_member_list': true,
    });
    expect(hidden.hideBotsInMemberList, isTrue);
  });

  test('setSpaceSettings sends the switch and nothing else', () async {
    late Map<String, dynamic> body;
    final api = _api((request) async {
      body = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode({'join_policy': 'invite', 'hide_bots_in_member_list': true}),
        200,
      );
    });
    final stored = await api.setSpaceSettings(
      const SpaceSettingsUpdate(hideBotsInMemberList: true),
    );
    expect(body, {'hide_bots_in_member_list': true});
    expect(stored.hideBotsInMemberList, isTrue);
  });
}
