// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas reads an HTTP-only agent uses: the op feed's `wait`, objects by
/// id, and the board summary.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

const _object = {
  'id': 'o1',
  'kind': 'stroke',
  'z_index': 1,
  'x': 1.0,
  'y': 2.0,
  'w': 3.0,
  'h': 4.0,
  'props': <String, Object>{},
  'author_id': 'u1',
  'seq': 1,
  'created_at': 1,
};

SlimmApi _api(Object body, void Function(http.Request) seen) => SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: SessionStore(
        tokens: const TokenPair(
          userId: 'u1',
          accessToken: 'access',
          refreshToken: 'refresh',
          accessExpiresAt: 0,
        ),
      ),
      httpClient: MockClient((request) async {
        seen(request);
        return http.Response(
          jsonEncode(body),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

void main() {
  test('canvasOps sends wait only when asked', () async {
    final queries = <Map<String, String>>[];
    final api = _api(
      {'ops': <Object>[], 'latest_seq': 0, 'has_more': false, 'reset': false},
      (request) => queries.add(request.url.queryParameters),
    );
    await api.canvasOps('c1', afterSeq: 3);
    await api.canvasOps('c1', afterSeq: 3, wait: 20);
    expect(queries[0].containsKey('wait'), isFalse);
    expect(queries[1]['wait'], '20');
  });

  test('canvasObjectsById joins the ids into one query value', () async {
    late http.Request sent;
    final api = _api(
      {
        'objects': [_object],
        'has_more': false,
        'latest_seq': 4,
      },
      (request) => sent = request,
    );
    final page = await api.canvasObjectsById('c1', objectIds: ['a', 'b']);
    expect(sent.url.path, '/channels/c1/canvas/objects');
    expect(sent.url.queryParameters, {'ids': 'a,b'});
    expect(page.objects.single.id, 'o1');
  });

  test('canvasObject reads one object by its path', () async {
    late http.Request sent;
    final api = _api(_object, (request) => sent = request);
    final object = await api.canvasObject('c1', 'o1');
    expect(sent.url.path, '/channels/c1/canvas/objects/o1');
    expect(object.w, 3.0);
  });

  test('canvasBoardSummary reads the bounds, and null for an empty board',
      () async {
    final full = await _api(
      {
        'count': 2,
        'latest_seq': 5,
        'bounds': {'min_x': -1, 'min_y': 2.5, 'max_x': 30, 'max_y': 40},
      },
      (_) {},
    ).canvasBoardSummary('c1');
    expect(full.count, 2);
    expect(full.latestSeq, 5);
    expect(full.bounds!.minX, -1.0);
    expect(full.bounds!.maxY, 40.0);

    final empty = await _api(
      {'count': 0, 'latest_seq': 0, 'bounds': null},
      (_) {},
    ).canvasBoardSummary('c1');
    expect(empty.bounds, isNull);
  });
}
