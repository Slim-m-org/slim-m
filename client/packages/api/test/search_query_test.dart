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
  'mentions': 'bob',
  'pinned': 'true',
  'after_date': '2026-01-01',
  'before_date': '2026-02-01',
  'after_ms': '10',
  'before_ms': '20',
  'before_id': 'm1',
  'include_threads': 'true',
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
        mentions: 'bob',
        pinned: true,
        afterDate: '2026-01-01',
        beforeDate: '2026-02-01',
        afterMs: 10,
        beforeMs: 20,
        beforeId: 'm1',
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
        mentions: 'bob',
        pinned: true,
        afterDate: '2026-01-01',
        beforeDate: '2026-02-01',
        afterMs: 10,
        beforeMs: 20,
        beforeId: 'm1',
      ),
    );
    expect(url.path, '/search/messages');
    expect(url.queryParameters, _every);
  });

  test('both routes ask for thread hits, which this client can open', () async {
    for (final call in <Future<void> Function(SlimmApi)>[
      (api) => api.searchMessages('c1', q: 'hello'),
      (api) => api.searchAllMessages(q: 'hello'),
    ]) {
      final url = await capture(call);
      expect(url.queryParameters['include_threads'], 'true');
    }
  });
}
