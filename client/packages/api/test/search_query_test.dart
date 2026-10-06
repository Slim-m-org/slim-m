// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Both search routes speak one operator set; pin it so the shared query
/// builder cannot drop one for either route.
library;

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

const _tokens = TokenPair(
  userId: 'u',
  accessToken: 'a',
  refreshToken: 'r',
  accessExpiresAt: 0,
);

const _every = {
  'q': 'hello',
  'before': '9',
  'limit': '5',
  'from': 'alice',
  'in': 'general',
  'has': 'link',
  'after_date': '2026-01-01',
  'before_date': '2026-02-01',
};

void main() {
  Future<Uri> capture(
    Future<void> Function(SlimmApi api) call,
  ) async {
    late Uri seen;
    final api = SlimmApi(
      baseUrl: Uri.parse('https://chat.example'),
      session: SessionStore(tokens: _tokens),
      httpClient: MockClient((request) async {
        seen = request.url;
        return http.Response('[]', 200);
      }),
    );
    await call(api);
    return seen;
  }

  test('searchMessages sends every operator on the channel route', () async {
    final url = await capture(
      (api) => api.searchMessages(
        'c1',
        q: 'hello',
        before: 9,
        limit: 5,
        from: 'alice',
        inChannel: 'general',
        has: 'link',
        afterDate: '2026-01-01',
        beforeDate: '2026-02-01',
      ),
    );
    expect(url.path, '/channels/c1/messages/search');
    expect(url.queryParameters, _every);
  });

  test('searchAllMessages sends every operator on the global route', () async {
    final url = await capture(
      (api) => api.searchAllMessages(
        q: 'hello',
        before: 9,
        limit: 5,
        from: 'alice',
        inChannel: 'general',
        has: 'link',
        afterDate: '2026-01-01',
        beforeDate: '2026-02-01',
      ),
    );
    expect(url.path, '/search/messages');
    expect(url.queryParameters, _every);
  });
}
