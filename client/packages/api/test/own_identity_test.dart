// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The caller's roles on `/me`, its permissions by name and the member lookup,
/// as the client sends and reads them.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

SlimmApi _api(Future<http.Response> Function(http.Request) handler) =>
    testApi(handler,
        session: SessionStore(
          tokens: const TokenPair(
            userId: 'u1',
            accessToken: 'access',
            refreshToken: 'refresh',
            accessExpiresAt: 0,
          ),
        ));

void main() {
  test('Me reads its roles and tolerates a server without them', () {
    const base = {
      'id': 'u1',
      'username': 'a',
      'display_name': 'A',
      'created_at': 1,
      'permissions': 0,
    };
    final me = Me.fromJson({
      ...base,
      'roles': ['mod'],
      'role_ids': ['r1'],
      'role_colors': [3, null],
    });
    expect(me.roles, ['mod']);
    expect(me.roleIds, ['r1']);
    expect(me.roleColors, [3, null]);
    expect(Me.fromJson(base).roles, isEmpty);
  });

  test('ownPermissions scopes to a channel and reads the names', () async {
    late http.Request seen;
    final api = _api((request) async {
      seen = request;
      return http.Response(
        jsonEncode({
          'permissions': 6,
          'names': ['view_channel', 'send_messages'],
          'channel_id': 'c1',
        }),
        200,
      );
    });
    final own = await api.ownPermissions(channelId: 'c1');
    expect(seen.url.path, endsWith('/me/permissions'));
    expect(seen.url.queryParameters, {'channel_id': 'c1'});
    expect(own.names, ['view_channel', 'send_messages']);
    expect(own.channelId, 'c1');
  });

  test('getMember asks the member route', () async {
    late http.Request seen;
    final api = _api((request) async {
      seen = request;
      return http.Response(
        jsonEncode({
          'id': 'u2',
          'username': 'b',
          'display_name': 'B',
          'created_at': 1,
        }),
        200,
      );
    });
    expect((await api.getMember('u2')).id, 'u2');
    expect(seen.url.path, endsWith('/members/u2'));
  });
}
