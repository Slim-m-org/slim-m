// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Avatar bytes survive losing their last watcher, which is what makes a
/// channel switch stop refetching every face in the pane.
///
/// The providers are `autoDispose` on purpose - a long member list must not
/// grow forever - so this is about the window, not about caching for good.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/members/providers/avatar_bytes.dart';
import 'package:slimm_app/src/providers/providers.dart';

const _tokens = TokenPair(
  userId: 'u1',
  accessToken: 'a',
  refreshToken: 'r',
  accessExpiresAt: 9999999999999,
);

void main() {
  test('a released avatar is not refetched inside the cache window', () async {
    var fetches = 0;
    final container = ProviderContainer(
      overrides: [
        sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
        apiProvider.overrideWith((ref) {
          return SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient((request) async {
              if (request.url.path.endsWith('/avatar')) {
                fetches += 1;
                return http.Response.bytes(
                  utf8.encode('png-bytes'),
                  200,
                  headers: {'content-type': 'image/png'},
                );
              }
              return http.Response('', 404);
            }),
          );
        }),
      ],
    );
    addTearDown(container.dispose);

    const key = (userId: 'u2', updatedAt: 1);

    // Watching the avatar, the way a mounted pane does.
    final first = container.listen(avatarBytesProvider(key), (_, _) {});
    await container.read(avatarBytesProvider(key).future);
    expect(fetches, 1);

    // Leaving the channel: the only watcher goes.
    first.close();
    await Future<void>.delayed(Duration.zero);

    // Coming back.
    container.listen(avatarBytesProvider(key), (_, _) {});
    await container.read(avatarBytesProvider(key).future);

    expect(
      fetches,
      1,
      reason: 'the bytes should still be held, not fetched again',
    );
  });
}
