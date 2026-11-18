// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// In a browser an upload's progress is what the network took, not what was
/// read into the request: `fetch` buffers the whole body first, so a bar fed
/// from the read sat at 100% from the first second of a slow upload.
@TestOn('browser')
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:http/browser_client.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

/// A server that holds the body unread until told to go, as a stalled link does.
const _slowServer = r'''
import 'dart:io';

import 'package:async/async.dart';
import 'package:stream_channel/stream_channel.dart';

Future<void> hybridMain(StreamChannel<Object?> channel) async {
  final queue = StreamQueue(channel.stream);
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
    // Takes none of the body until the test has seen a first report, so the send stalls part way.
    await queue.next;
    await request.drain<void>();
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
    // Past what loopback socket buffers hold, so a stalled send cannot have taken it all.
    const length = 48 * 1024 * 1024;
    final reports = <int>[];
    final first = Completer<int>();

    final upload = api.uploadAttachmentStream(
      () => Stream.value(Uint8List(length)),
      length: length,
      filename: 'big.bin',
      onProgress: (sent) {
        reports.add(sent);
        if (!first.isCompleted) first.complete(sent);
      },
    );

    expect(await first.future, lessThan(length),
        reason: 'not done from the start');
    hybrid.sink.add('go');
    final attachment = await upload;

    expect(attachment.id, 'a1');
    expect(reports.last, length);
    await hybrid.sink.close();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
