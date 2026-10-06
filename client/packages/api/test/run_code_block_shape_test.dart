// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A 200 whose body is not the run result shape is a transport failure the
/// caller can handle, not a TypeError that escapes the ApiException catches.
library;

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

SlimmApi _api(String body) => SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: SessionStore(
        tokens: const TokenPair(
          userId: 'u1',
          accessToken: 'access',
          refreshToken: 'refresh',
          accessExpiresAt: 0,
        ),
      ),
      httpClient: MockClient((request) async => http.Response(body, 200)),
    );

void main() {
  for (final body in ['{}', '[]', '', '"text"']) {
    test('runCodeBlock with a 200 body of "$body" throws TransportException',
        () {
      expect(
        _api(body).runCodeBlock(
          messageId: 'm',
          blockIndex: 0,
          moduleId: 'mod',
          command: 'open',
          input: '',
        ),
        throwsA(isA<TransportException>()),
      );
    });
  }
}
