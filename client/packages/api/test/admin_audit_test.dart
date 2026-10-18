// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `GET /space/audit-log`: the model and the paging query.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

SlimmApi _api(MockClientHandler handler) => SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: SessionStore(
        tokens: const TokenPair(
          userId: 'u',
          accessToken: 'a',
          refreshToken: 'r',
          accessExpiresAt: 0,
        ),
      ),
      httpClient: MockClient(handler),
    );

void main() {
  test('parses a change with every detail key', () {
    final change = AdminChange.fromJson({
      'id': 7,
      'actor_id': 'actor',
      'action': 'role.assign',
      'target_id': 'user-1',
      'detail': {
        'fields': ['name', 'color'],
        'name': 'Mods',
        'params': {'role_id': 'role-1'},
      },
      'created_at': 1000,
    });
    expect(change.id, 7);
    expect(change.fields, ['name', 'color']);
    expect(change.name, 'Mods');
    expect(change.param('role_id'), 'role-1');
    expect(change.param('module_id'), isNull);
  });

  test('parses a change with a null actor, null target and empty detail', () {
    final change = AdminChange.fromJson({
      'id': 1,
      'actor_id': null,
      'action': 'space.update',
      'target_id': null,
      'detail': <String, dynamic>{},
      'created_at': 5,
    });
    expect(change.actorId, isNull);
    expect(change.targetId, isNull);
    expect(change.fields, isEmpty);
    expect(change.name, isNull);
  });

  test('listAdminChanges sends before and limit and keeps the order', () async {
    Uri? seen;
    final api = _api((request) async {
      seen = request.url;
      return http.Response(
        jsonEncode([
          for (final id in [9, 8])
            {
              'id': id,
              'actor_id': null,
              'action': 'channel.delete',
              'target_id': 'c$id',
              'detail': <String, dynamic>{},
              'created_at': id,
            },
        ]),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final page = await api.listAdminChanges(before: 10, limit: 2);
    expect(seen?.path, '/space/audit-log');
    expect(seen?.queryParameters, {'before': '10', 'limit': '2'});
    expect(page.map((c) => c.id), [9, 8]);
  });

  test('listAdminChanges sends no query for the first page', () async {
    Uri? seen;
    final api = _api((request) async {
      seen = request.url;
      return http.Response('[]', 200,
          headers: {'content-type': 'application/json'});
    });
    expect(await api.listAdminChanges(), isEmpty);
    expect(seen?.hasQuery, isFalse);
  });
}
