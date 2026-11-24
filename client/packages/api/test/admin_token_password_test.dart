// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The caller's password rides the requests that mint, raise or reissue an ADMINISTRATOR token.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_test_support/slimm_test_support.dart';
import 'package:test/test.dart';

const _bot = {
  'user_id': 'b1',
  'username': 'helper',
  'display_name': 'helper',
  'created_at': 1,
  'permissions': 1,
  'online': false,
};

SlimmApi _recording(List<http.Request> seen) => testApi((request) async {
      seen.add(request);
      final path = request.url.path;
      if (path.endsWith('/connector-token')) {
        return http.Response(jsonEncode({'token': 't'}), 200);
      }
      if (request.method == 'PATCH') {
        return http.Response(jsonEncode(_bot), 200);
      }
      return http.Response(jsonEncode({'bot': _bot, 'token': 't'}), 200);
    });

Map<String, dynamic> _body(http.Request r) =>
    r.body.isEmpty ? {} : jsonDecode(r.body) as Map<String, dynamic>;

void main() {
  test('createBot sends the password only when given', () async {
    final seen = <http.Request>[];
    final api = _recording(seen);
    await api.createBot('helper', permissions: 1, password: 'pw');
    await api.createBot('helper');
    expect(_body(seen[0])['password'], 'pw');
    expect(_body(seen[1]).containsKey('password'), isFalse);
  });

  test('setBotPermissions sends the password only when given', () async {
    final seen = <http.Request>[];
    final api = _recording(seen);
    await api.setBotPermissions('b1', 1, password: 'pw');
    await api.setBotPermissions('b1', 0);
    expect(_body(seen[0]), {'permissions': 1, 'password': 'pw'});
    expect(_body(seen[1]), {'permissions': 0});
  });

  test('reissueBotToken sends the password as the JSON body', () async {
    final seen = <http.Request>[];
    final api = _recording(seen);
    await api.reissueBotToken('b1', password: 'pw');
    await api.reissueBotToken('b1');
    expect(_body(seen[0]), {'password': 'pw'});
    expect(seen[1].body, isEmpty);
  });

  test('reissueConnectorToken sends the password as the JSON body', () async {
    final seen = <http.Request>[];
    final api = _recording(seen);
    await api.reissueConnectorToken('mod', password: 'pw');
    await api.reissueConnectorToken('mod');
    expect(_body(seen[0]), {'password': 'pw'});
    expect(seen[1].body, isEmpty);
  });
}
