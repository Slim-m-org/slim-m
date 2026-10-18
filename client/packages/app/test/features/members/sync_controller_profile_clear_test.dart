// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Regression test for the other half of profile-name reconciliation:
/// `SyncController.start()` forgets every cached author name on every
/// (re)connect, since there is no cursor over a rename to catch up from and
/// a session that missed a `profile.changed` frame while disconnected has no
/// other way to learn the current value.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_platform/platform.dart';
import '../../support/fake_api.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

void main() {
  test('a (re)connect forgets every cached author name', () async {
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
        mockApiOverride((request) async {
          if (request.url.path == '/users') {
            return http.Response(
              jsonEncode([
                {
                  'id': 'u1',
                  'username': 'u1',
                  'display_name': 'Dave',
                  'created_at': 0,
                },
              ]),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          // Any other route: the reconnect only needs to reach clear(), not to complete.
          return http.Response('unavailable', 500);
        }),
      ],
    );
    addTearDown(container.dispose);

    // Wait out the constructor's own initial start() before the manual reconnect below.
    await container.read(syncControllerProvider.notifier).start();

    await container.read(batchProfilesControllerProvider.notifier).resolve([
      'u1',
    ]);
    expect(container.read(batchProfilesControllerProvider), isNotEmpty);

    await container.read(syncControllerProvider.notifier).start();

    expect(
      container.read(batchProfilesControllerProvider),
      isEmpty,
      reason: 'a fresh connect must not carry a name that may be stale',
    );
  });
}
