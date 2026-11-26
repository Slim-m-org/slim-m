// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `speakTts` (decision 0142): the request it sends and how it reads the queue.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

SlimmApi _api(Future<http.Response> Function(http.Request) handler) => SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: SessionStore(
        tokens: const TokenPair(
          userId: 'user-1',
          accessToken: 'access-1',
          refreshToken: 'refresh-1',
          accessExpiresAt: 0,
        ),
      ),
      httpClient: MockClient(handler),
    );

void main() {
  test('posts the line to the call route and returns how many are ahead',
      () async {
    late http.Request seen;
    final api = _api((request) async {
      seen = request;
      return http.Response(jsonEncode({'ahead': 2}), 202,
          headers: {'content-type': 'application/json'});
    });
    expect(await api.speakTts('c1', 'hello there'), 2);
    expect((seen.method, seen.url.path), ('POST', '/channels/c1/voice/tts'));
    expect(jsonDecode(seen.body), {'text': 'hello there'});
  });

  test('a server with no voice is a NotConfiguredException', () async {
    final api = _api((_) async => http.Response(
        jsonEncode({'error': 'text to speech is not set up on this server'}),
        501,
        headers: {'content-type': 'application/json'}));
    await expectLater(
        api.speakTts('c1', 'hi'), throwsA(isA<NotConfiguredException>()));
  });
}
