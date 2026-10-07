// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/member_presence.dart';
import 'package:slimm_app/src/providers/presence_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

api.UserProfile _profile(String name) => api.UserProfile(
  id: 'user-2',
  username: 'bob',
  displayName: name,
  createdAt: 0,
);

class _OfflineSyncController extends SyncController {
  _OfflineSyncController(super.ref);

  @override
  Future<void> start() async {}
}

void main() {
  test('signing out forgets the visibility the last account picked', () async {
    final session = api.SessionStore(tokens: _tokens);
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(session),
        syncControllerProvider.overrideWith(_OfflineSyncController.new),
        storeProvider.overrideWith((ref) async => throw StateError('n/a')),
      ],
    );
    addTearDown(container.dispose);

    container.read(syncControllerProvider.notifier);
    container.read(presenceVisibilityDisplayProvider.notifier).state =
        api.PresenceVisibility.hidden;

    session.clear();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(container.read(presenceVisibilityDisplayProvider), isNull);
  });

  test(
    'signing out drops profile overrides from the previous account',
    () async {
      final session = api.SessionStore(tokens: _tokens);
      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(session),
          syncControllerProvider.overrideWith(_OfflineSyncController.new),
          storeProvider.overrideWith((ref) async => throw StateError('n/a')),
        ],
      );
      addTearDown(container.dispose);

      container.read(syncControllerProvider.notifier);
      container
          .read(memberProfileOverridesProvider.notifier)
          .applyKnown(_profile('Stale Bob'));
      expect(container.read(memberProfileOverridesProvider), isNotEmpty);

      session.clear();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(container.read(memberProfileOverridesProvider), isEmpty);
    },
  );

  test(
    'a refetch finishing after the notifier is disposed does not throw',
    () async {
      final events = StreamController<api.ServerEvent>.broadcast();
      final gate = Completer<void>();
      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
          liveEventsProvider.overrideWithValue(events.stream),
          apiProvider.overrideWith(
            (ref) => api.SlimmApi(
              baseUrl: Uri.parse('http://localhost:8080'),
              session: ref.watch(sessionProvider),
              httpClient: MockClient((request) async {
                await gate.future;
                return http.Response(
                  jsonEncode({
                    'id': 'user-2',
                    'username': 'bob',
                    'display_name': 'Fresh',
                    'created_at': 0,
                  }),
                  200,
                  headers: {'content-type': 'application/json'},
                );
              }),
            ),
          ),
        ],
      );
      container.read(memberProfileOverridesProvider.notifier);
      final errors = <Object>[];
      await runZonedGuarded(() async {
        events.add(const api.ProfileChanged(userId: 'user-2'));
        await Future<void>.delayed(Duration.zero);
        container.invalidate(memberProfileOverridesProvider);
        container.read(memberProfileOverridesProvider);
        gate.complete();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }, (e, _) => errors.add(e));
      container.dispose();
      expect(errors, isEmpty);
    },
  );
}
