// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `POST /channels/{id}/canvas/ops/batch`: the ops go out in order and the results come back decoded.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

Map<String, Object?> _result(String id, int seq, String kind) => {
      'op': {
        'id': id,
        'seq': seq,
        'kind': kind,
        'affected': 1,
        'created_at': 0,
      },
      'fresh': true,
    };

void main() {
  test('submitCanvasOpBatch posts the ops and decodes each result', () async {
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
            'ops': [_result('a', 5, 'move'), _result('b', 6, 'edit')],
          }),
          201,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final results = await api.submitCanvasOpBatch('c1', const [
      CanvasOpInput(
          id: 'a', kind: 'move', objectId: 'o1', x: 1, y: 2, w: 3, h: 4),
      CanvasOpInput(id: 'b', kind: 'edit', objectId: 'o2', props: {'a': 1}),
    ]);
    expect(path, '/channels/c1/canvas/ops/batch');
    final sent = (body!['ops'] as List).cast<Map<String, dynamic>>();
    expect([for (final o in sent) o['id']], ['a', 'b']);
    expect(sent[1].containsKey('x'), isFalse);
    expect([for (final r in results) r.op.seq], [5, 6]);
  });
}
