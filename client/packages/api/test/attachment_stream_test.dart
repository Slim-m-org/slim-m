// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The streamed attachment upload, and the server limit it is checked against.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

final _base = Uri.parse('http://localhost:8080');

SessionStore _session() => SessionStore(
      tokens: const TokenPair(
        userId: 'u',
        accessToken: 'access',
        refreshToken: 'refresh',
        accessExpiresAt: 0,
      ),
    );

void main() {
  test('uploadAttachmentStream sends the streamed bytes and reports progress',
      () async {
    List<int>? sentBytes;
    final api = SlimmApi(
      baseUrl: _base,
      session: _session(),
      httpClient: MockClient((request) async {
        sentBytes = request.bodyBytes;
        return http.Response(
          jsonEncode({
            'id': 'deadbeef',
            'filename': 'big.iso',
            'content_type': 'image/png',
            'size': 6,
          }),
          201,
        );
      }),
    );
    final progress = <int>[];
    final attachment = await api.uploadAttachmentStream(
      () => Stream.fromIterable([
        [1, 2],
        [3, 4, 5, 6],
      ]),
      length: 6,
      filename: 'big.iso',
      onProgress: progress.add,
    );
    expect(sentBytes, [1, 2, 3, 4, 5, 6]);
    expect(progress, [2, 6]);
    expect(attachment.id, 'deadbeef');
  });

  test('uploadAttachmentStream maps a refusal to the usual exception',
      () async {
    final api = SlimmApi(
      baseUrl: _base,
      session: _session(),
      httpClient: MockClient((_) async => http.Response('too big', 413)),
    );
    await expectLater(
      api.uploadAttachmentStream(() => Stream.value([1]), length: 1),
      throwsA(isA<ServerException>()),
    );
  });

  test('Version carries the attachment ceiling when the server sends it', () {
    final v = Version.fromJson({
      'name': 'slim-m',
      'version': '1.0.0',
      'protocol': 1,
      'max_attachment_bytes': 104857600,
    });
    expect(v.maxAttachmentBytes, 104857600);
    final old = Version.fromJson({
      'name': 'n',
      'version': 'v',
      'protocol': 1,
    });
    expect(old.maxAttachmentBytes, isNull);
  });
}
