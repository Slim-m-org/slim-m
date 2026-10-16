// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  accessExpiresAt: 0,
);

SlimmApi _api(MockClient client) => SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: SessionStore(tokens: _tokens),
      httpClient: client,
    );

void main() {
  test('opens the body as a stream with its declared length and type',
      () async {
    String? auth;
    final api = _api(
      MockClient.streaming((request, _) async {
        auth = request.headers['authorization'];
        return http.StreamedResponse(
          Stream.fromIterable([
            [1, 2],
            [3],
          ]),
          200,
          contentLength: 3,
          headers: {'content-type': 'application/zip'},
        );
      }),
    );
    final download = await api.openAttachmentDownload('abc');
    expect(auth, 'Bearer access-1');
    expect(download.contentLength, 3);
    expect(download.contentType, 'application/zip');
    final chunks = await download.body.toList();
    expect(chunks.expand((c) => c), [1, 2, 3]);
  });

  test('cancelling the body subscription reaches the source stream', () async {
    var cancelled = false;
    final source = StreamController<List<int>>(
      onCancel: () => cancelled = true,
    );
    final api = _api(
      MockClient.streaming(
        (request, _) async => http.StreamedResponse(source.stream, 200),
      ),
    );
    final download = await api.openAttachmentDownload('abc');
    final sub = download.body.listen((_) {});
    source.add([1]);
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(cancelled, isTrue);
  });

  test('a refusal maps to the typed exception, not a stream', () async {
    final api = _api(
      MockClient.streaming(
        (request, _) async => http.StreamedResponse(Stream.value([]), 403),
      ),
    );
    expect(
      api.openAttachmentDownload('abc'),
      throwsA(isA<ForbiddenException>()),
    );
  });
}
