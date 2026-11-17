// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The roster a stale session failed to fetch is fetched again by the next
/// sign-in, even while something else (the desktop notifier) keeps it alive.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/testing.dart';

const _stale = TokenPair(
  userId: 'old-alice',
  accessToken: 'stale',
  refreshToken: 'stale-refresh',
  accessExpiresAt: 0,
);

const _fresh = TokenPair(
  userId: 'alice',
  accessToken: 'fresh',
  refreshToken: 'fresh-refresh',
  accessExpiresAt: 0,
);

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  test('a sign-in refetches the roster the stale session failed', () async {
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        apiProvider.overrideWith((ref) {
          final api = SlimmApi(
            baseUrl: ref.watch(serverUrlProvider),
            session: ref.read(sessionProvider),
            httpClient: MockClient((request) async {
              final fresh = request.headers['authorization'] == 'Bearer fresh';
              if (request.url.path == '/members' && fresh) {
                return _json([
                  {
                    'id': 'alice',
                    'username': 'alice',
                    'display_name': 'Alice',
                    'created_at': 0,
                  },
                ]);
              }
              return _json({'error': 'unauthorized'}, 401);
            }),
          );
          ref.onDispose(api.close);
          return api;
        }),
      ],
    );
    addTearDown(container.dispose);
    container.read(sessionProvider).set(_stale);
    final kept = container.listen(membersProvider, (_, _) {});
    addTearDown(kept.close);

    await pumpEventQueue();
    expect(container.read(sessionProvider).isSignedIn, isFalse);

    container.read(sessionProvider).set(_fresh);
    await pumpEventQueue();
    final members = await container.read(membersProvider.future);
    expect(members.map((m) => m.id), ['alice']);
  });
}
