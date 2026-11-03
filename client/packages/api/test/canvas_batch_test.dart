// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `POST /channels/{id}/canvas/objects/batch`: the objects go out in order and come back decoded.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

Map<String, Object?> _object(String id, int seq) => {
      'id': id,
      'kind': 'stroke',
      'z_index': seq,
      'x': 1.0,
      'y': 2.0,
      'w': 3.0,
      'h': 4.0,
      'props': <String, Object?>{},
      'author_id': 'u1',
      'seq': seq,
      'created_at': 0,
    };

void main() {
  test('placeCanvasObjects posts the list and decodes the stored objects',
      () async {
    String? path;
    Map<String, dynamic>? body;
    final api = SlimmApi(
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
        path = request.url.path;
        body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'objects': [_object('a', 5), _object('b', 6)],
          }),
          201,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final placed = await api.placeCanvasObjects('c1', const [
      CanvasPlacement(
          id: 'a', kind: 'stroke', x: 1, y: 2, w: 3, h: 4, props: {}),
      CanvasPlacement(
          id: 'b', kind: 'stroke', x: 1, y: 2, w: 3, h: 4, props: {}),
    ]);
    expect(path, '/channels/c1/canvas/objects/batch');
    expect([for (final o in body!['objects'] as List) (o as Map)['id']],
        ['a', 'b']);
    expect([for (final o in placed) o.seq], [5, 6]);
  });
}
