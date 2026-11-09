// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A 2xx whose body is not the JSON the call promises still surfaces as an
/// [ApiException], so the catches that expect one (and the resumable upload,
/// which keeps its session for a transient one) see it.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

final _base = Uri.parse('http://localhost:8080');

const _portal = '<html>sign in to the wifi</html>';

SlimmApi _api(MockClientHandler handler) => SlimmApi(
      baseUrl: _base,
      session: SessionStore(
        tokens: const TokenPair(
          userId: 'u',
          accessToken: 'access',
          refreshToken: 'refresh',
          accessExpiresAt: 0,
        ),
      ),
      httpClient: MockClient(handler),
    );

http.Response _json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

void main() {
  test(
      'a part answered with a captive portal page keeps the resumable session '
      'instead of discarding it', () async {
    final calls = <String>[];
    final api = _api((request) async {
      calls.add('${request.method} ${request.url.path}');
      if (request.method == 'POST' && request.url.path.endsWith('/uploads')) {
        return _json({
          'id': 'up1',
          'size': 20,
          'offset': 0,
          'part_max_bytes': 20,
          'expires_at': 0,
        }, 201);
      }
      if (request.method == 'GET') {
        return _json({
          'id': 'up1',
          'size': 20,
          'offset': 0,
          'part_max_bytes': 20,
          'expires_at': 0,
        });
      }
      if (request.method == 'DELETE') return http.Response('', 204);
      return http.Response(_portal, 200);
    });

    await expectLater(
      api.uploadAttachmentAuto(
        UploadSource(open: () => Stream.value(List.filled(20, 1))),
        length: 20,
        capabilities: const ['upload_sessions'],
        sessionThreshold: 0,
        resumeKey: 'tile-1',
        backoff: (_) => const Duration(milliseconds: 5),
        stallLimit: const Duration(milliseconds: 50),
        partBytes: 20,
      ),
      throwsA(isA<UnreadableReplyException>()),
    );
    await Future<void>.delayed(Duration.zero);

    expect(calls, isNot(contains('DELETE /attachments/uploads/up1')));
  });

  test('a streamed upload answered with a non-JSON body is an ApiException',
      () async {
    final api = _api((_) async => http.Response(_portal, 201));
    await expectLater(
      api.uploadAttachmentStream(() => Stream.value([1, 2]), length: 2),
      throwsA(isA<UnreadableReplyException>()),
    );
  });

  test('a streamed upload answered with the wrong JSON shape is too', () async {
    final api = _api((_) async => _json(['not', 'an', 'attachment'], 201));
    await expectLater(
      api.uploadAttachmentStream(() => Stream.value([1, 2]), length: 2),
      throwsA(isA<TransportException>()),
    );
  });

  test('a canvas page answered with the wrong JSON shape is an ApiException',
      () async {
    final api = _api((_) async => _json(['not', 'a', 'page']));
    await expectLater(
      api.canvasViewportPage(
        'c1',
        region: const CanvasRect(minX: 0, minY: 0, maxX: 1, maxY: 1),
        cursorSeq: 0,
      ),
      throwsA(isA<TransportException>()),
    );
  });
}
