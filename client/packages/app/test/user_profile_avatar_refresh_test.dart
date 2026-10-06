// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/user_profiles.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

void main() {
  for (final how in ['profile.changed frame', 'reconnect clear()']) {
    test(
      'a mounted avatar picks up a new avatarUpdatedAt after a $how',
      () async {
        final events = StreamController<ServerEvent>.broadcast();
        addTearDown(events.close);
        var avatarVersion = 1;
        final container = ProviderContainer(
          overrides: [
            keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
            sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
            liveEventsProvider.overrideWithValue(events.stream),
            apiProvider.overrideWith((ref) {
              final api = SlimmApi(
                baseUrl: Uri.parse('http://localhost:8080'),
                session: ref.watch(sessionProvider),
                httpClient: MockClient((request) async {
                  final ids = request.url.queryParameters['ids']!.split(',');
                  return http.Response(
                    jsonEncode([
                      for (final id in ids)
                        {
                          'id': id,
                          'username': id,
                          'display_name': 'User $id',
                          'created_at': 0,
                          'avatar_updated_at': avatarVersion,
                        },
                    ]),
                    200,
                    headers: {'content-type': 'application/json'},
                  );
                }),
              );
              ref.onDispose(api.close);
              return api;
            }),
          ],
        );
        addTearDown(container.dispose);

        // The same watch UserAvatar's _avatarVersionProvider holds for the whole life of a mounted avatar.
        final seen = <int?>[];
        container.listen<int?>(
          userProfileProvider(
            'u1',
          ).select((p) => p.valueOrNull?.avatarUpdatedAt),
          (_, next) => seen.add(next),
          fireImmediately: true,
        );
        container.read(batchProfilesControllerProvider);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(seen.last, 1, reason: 'sanity: first resolve');

        avatarVersion = 2;
        if (how == 'reconnect clear()') {
          container.read(batchProfilesControllerProvider.notifier).clear();
        } else {
          events.add(const ProfileChanged(userId: 'u1'));
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(seen.last, 2, reason: 'seen so far: $seen');
      },
    );
  }
}
