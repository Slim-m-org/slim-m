// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Regression test for the caller's own profile being fetched once per
/// process: a second sign-in within one launch used to draw the first
/// account's cached identity, since [meProvider] was never invalidated on
/// the session actually changing. See sync_controller.dart's session
/// listener.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart' show MessageStore, SlimmDatabase;
import 'package:slimm_platform/testing.dart';

void main() {
  test('a second sign-in in the same process fetches the new account\'s own '
      'profile rather than reusing the first account\'s cached one', () async {
    const tokensA = TokenPair(
      userId: 'user-a',
      accessToken: 'access-a',
      refreshToken: 'refresh-a',
      accessExpiresAt: 0,
    );
    const tokensB = TokenPair(
      userId: 'user-b',
      accessToken: 'access-b',
      refreshToken: 'refresh-b',
      accessExpiresAt: 0,
    );

    final db = SlimmDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        storeProvider.overrideWith((ref) async => MessageStore(db)),
        apiProvider.overrideWith((ref) {
          final api = SlimmApi(
            baseUrl: ref.watch(serverUrlProvider),
            session: ref.watch(sessionProvider),
            httpClient: MockClient((request) async {
              if (request.url.path == '/auth/logout') {
                return http.Response('', 204);
              }
              if (request.url.path == '/channels') {
                return http.Response('[]', 200);
              }

              final auth = request.headers['authorization'];
              final id = auth == 'Bearer access-a' ? 'user-a' : 'user-b';
              return http.Response(
                jsonEncode({
                  'id': id,
                  'username': id,
                  'display_name': id,
                  'created_at': 0,
                  'permissions': 0,
                }),
                200,
              );
            }),
          );
          ref.onDispose(api.close);
          return api;
        }),
      ],
    );
    addTearDown(container.dispose);

    // Bring the sync controller up so a sign-out ends the way the app shell's does.
    container.read(syncControllerProvider.notifier);
    container.read(sessionProvider).set(tokensA);
    await pumpEventQueue();

    // A persistent watcher, the way the rail footer keeps meProvider alive.
    final sub = container.listen(meProvider, (_, __) {});
    addTearDown(sub.close);
    await pumpEventQueue();
    expect(container.read(meProvider).value?.id, 'user-a');

    await container.read(apiProvider).logout();
    await pumpEventQueue();

    /// Asserted on the state rather than on `.value` or on a request count.
    /// An invalidated [FutureProvider] carries its previous data through the
    /// reload, so `.value` still answers with the departed account either
    /// way; and a signed-out client refuses the read before sending it, so
    /// no request is made to count. What does change is that the provider
    /// stops being settled data somebody can go on rendering.
    expect(
      container.read(meProvider),
      isNot(isA<AsyncData<Me>>()),
      reason:
          'sign-out must unsettle the caller\'s own identity, or a watcher '
          'outliving it goes on being served the departed account\'s '
          'profile as though it were still current',
    );

    container.read(sessionProvider).set(tokensB);
    await pumpEventQueue();

    expect(
      container.read(meProvider).value?.id,
      'user-b',
      reason: 'the second account\'s identity must replace the first\'s',
    );
  });
}
