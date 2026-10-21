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

  test('canvasViewportPage pages by cursor and reads the totals', () async {
    Map<String, String>? query;
    final api = SlimmApi(
      baseUrl: _base,
      session: SessionStore(tokens: _tokens()),
      httpClient: MockClient((request) async {
        query = request.url.queryParameters;
        return http.Response(
          jsonEncode({
            'objects': <Object>[],
            'has_more': true,
            'latest_seq': 9,
            'next_cursor': 4,
            'total_objects': 12,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final page = await api.canvasViewportPage(
      'c1',
      region: const CanvasRect(minX: -1, minY: -2, maxX: 3, maxY: 4),
      cursorSeq: 0,
      limit: 500,
    );
    expect(query!['cursor_seq'], '0');
    expect((page.nextCursor, page.totalObjects), (4, 12));
  });

  test('purgeCanvasObject deletes the object and answers its last row',
      () async {
    http.Request? seen;
    final api = SlimmApi(
      baseUrl: _base,
      session: SessionStore(tokens: _tokens()),
      httpClient: MockClient((request) async {
        seen = request;
        return http.Response(
          jsonEncode({
            'id': 'o1',
            'kind': 'note',
            'z_index': 3,
            'x': 1.0,
            'y': 2.0,
            'w': 30.0,
            'h': 40.0,
            'props': {'text': 'hi'},
            'author_id': 'u1',
            'seq': 9,
            'created_at': 5,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final row = await api.purgeCanvasObject('c1', 'o1');
    expect((row.id, row.kind, row.props['text']), ('o1', 'note', 'hi'));
    expect(seen!.method, 'DELETE');
    expect(seen!.url.path, '/channels/c1/canvas/objects/o1');
  });
}
