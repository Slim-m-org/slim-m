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
}
