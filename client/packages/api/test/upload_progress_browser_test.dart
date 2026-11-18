// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// In a browser an upload's progress is what the network took, not what was
/// read into the request: `fetch` buffers the whole body first, so a bar fed
/// from the read sat at 100% from the first second of a slow upload.
@TestOn('browser')
library;

import 'package:http/browser_client.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

/// A server that takes the body slowly, as a throttled link does.
const _slowServer = r'''
import 'dart:io';

import 'package:stream_channel/stream_channel.dart';

Future<void> hybridMain(StreamChannel<Object?> channel) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  channel.sink.add(server.port);
  await for (final request in server) {
    final response = request.response
      ..headers.set('access-control-allow-origin', '*')
      ..headers.set('access-control-allow-headers', '*')
      ..headers.set('access-control-allow-methods', 'POST');
    if (request.method == 'OPTIONS') {
      await response.close();
      continue;
    }
    await for (final _ in request) {
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    response
      ..statusCode = 201
      ..headers.contentType = ContentType.json
      ..write('{"id":"a1","filename":"big.bin","content_type":"application/octet-stream","size":8}');
    await response.close();
  }
}
''';

void main() {
  test('progress climbs while the bytes are still on their way', () async {
    final hybrid = spawnHybridCode(_slowServer);
    final port = await hybrid.stream.first as int;
    final api = SlimmApi(
      baseUrl: Uri.parse('http://127.0.0.1:$port'),
      session: SessionStore(
        tokens: const TokenPair(
          userId: 'u',
          accessToken: 'access',
          refreshToken: 'refresh',
          accessExpiresAt: 0,
        ),
      ),
      httpClient: BrowserClient(),
    );
    const length = 16 * 1024 * 1024;
    final reports = <int>[];

    final attachment = await api.uploadAttachmentStream(
      () => Stream.value(List<int>.filled(length, 7)),
      length: length,
      filename: 'big.bin',
      onProgress: reports.add,
    );

    expect(attachment.id, 'a1');
    expect(reports.first, lessThan(length), reason: 'not done from the start');
    expect(reports.last, length);
    await hybrid.sink.close();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
