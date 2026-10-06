// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `GET /channels/{id}/canvas/objects`: the viewport read is always a cold
/// fetch, since catching up goes through the op stream instead.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

final _base = Uri.parse('http://localhost:8080');

TokenPair _tokens() => const TokenPair(
      userId: 'u1',
      accessToken: 'access',
      refreshToken: 'refresh',
      accessExpiresAt: 0,
    );

void main() {
  test('canvasViewport sends only the region and the limit', () async {
    Map<String, String>? query;
    final api = SlimmApi(
      baseUrl: _base,
      session: SessionStore(tokens: _tokens()),
      httpClient: MockClient((request) async {
        query = request.url.queryParameters;
        return http.Response(
          jsonEncode(
              {'objects': <Object>[], 'has_more': false, 'latest_seq': 7}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final page = await api.canvasViewport(
      'c1',
      region: const CanvasRect(minX: -1, minY: -2, maxX: 3, maxY: 4),
      limit: 2000,
    );
    expect(page.latestSeq, 7);
    expect(query!.keys.toSet(), {
      'min_x',
      'min_y',
      'max_x',
      'max_y',
      'limit',
    });
  });
}
