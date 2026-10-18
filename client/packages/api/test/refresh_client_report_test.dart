// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A refresh reports this app's kind and version, so the server's devices
/// list follows an update instead of keeping the version it signed in with.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

Future<Map<String, dynamic>> _refreshBody(
  ({String kind, String? version})? report,
) async {
  late Map<String, dynamic> body;
  final api = SlimmApi(
    baseUrl: Uri.parse('http://localhost:8080'),
    session: SessionStore(
      tokens: const TokenPair(
        userId: 'user-1',
        accessToken: 'access-1',
        refreshToken: 'refresh-1',
        accessExpiresAt: 0,
      ),
    ),
    httpClient: MockClient((request) async {
      body = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode({
          'user_id': 'user-1',
          'access_token': 'access-2',
          'refresh_token': 'refresh-2',
          'access_expires_at': 99,
        }),
        200,
      );
    }),
  )..clientReport = report;
  await api.refresh();
  return body;
}

void main() {
  test('the kind and version ride along with the refresh token', () async {
    expect(await _refreshBody((kind: 'desktop', version: '0.107.0')), {
      'refresh_token': 'refresh-1',
      'client_kind': 'desktop',
      'client_version': '0.107.0',
    });
  });

  test('a version not read yet is left out rather than sent empty', () async {
    expect(await _refreshBody((kind: 'ios', version: null)), {
      'refresh_token': 'refresh-1',
      'client_kind': 'ios',
    });
  });

  test('no report sends the token alone, as before', () async {
    expect(await _refreshBody(null), {'refresh_token': 'refresh-1'});
  });
}
