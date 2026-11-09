// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

final _base = Uri.parse('https://slim.test');

SlimmApi _api(List<String> calls) {
  var dropped = false;
  return SlimmApi(
    baseUrl: _base,
    session: SessionStore(
      tokens: const TokenPair(
        userId: 'user-1',
        accessToken: 'access',
        refreshToken: 'refresh',
        accessExpiresAt: 0,
      ),
    ),
    httpClient: MockClient((request) async {
      calls.add('${request.method} ${request.url.path}');
      // The first request after waking rides a socket the OS already closed.
      if (!dropped) {
        dropped = true;
        throw http.ClientException(
          'Connection closed before full header was received',
        );
      }
      return http.Response('[]', 200);
    }),
  );
}

void main() {
  test('a read on a dead pooled connection is sent again on a fresh one',
      () async {
    final calls = <String>[];
    await _api(calls).listChannels();
    expect(calls, ['GET /channels', 'GET /channels']);
  });

  test('a POST is never repeated, since it may already have landed', () async {
    final calls = <String>[];
    await expectLater(
      _api(calls).webSocketTicket(),
      throwsA(isA<ConnectionDroppedException>()),
    );
    expect(calls, hasLength(1));
  });

  test('a byte fetch on a dead pooled connection is sent again too', () async {
    final calls = <String>[];
    final fetched = await _api(calls).fetchAttachment('a');
    expect(calls, ['GET /attachments/a', 'GET /attachments/a']);
    expect(fetched.bytes, isNotEmpty);
  });

  test('a streamed download on a dead pooled connection is sent again too',
      () async {
    final calls = <String>[];
    final download = await _api(calls).openAttachmentDownload('a');
    await download.body.drain<void>();
    expect(calls, ['GET /attachments/a', 'GET /attachments/a']);
  });

  test('a download that keeps dropping gives up after the one repeat',
      () async {
    var sent = 0;
    final api = SlimmApi(
      baseUrl: _base,
      session: SessionStore(
        tokens: const TokenPair(
          userId: 'user-1',
          accessToken: 'access',
          refreshToken: 'refresh',
          accessExpiresAt: 0,
        ),
      ),
      httpClient: MockClient((request) async {
        sent++;
        throw http.ClientException('Connection closed');
      }),
    );
    await expectLater(
      api.openAttachmentDownload('a'),
      throwsA(isA<ConnectionDroppedException>()),
    );
    expect(sent, 2);
  });
}
