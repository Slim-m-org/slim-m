// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' hide Channel;
import 'package:slimm_app/src/providers/channel_order_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

ProviderContainer _container(http.Response Function(http.Request) handler) {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async => handler(request)),
        );
        ref.onDispose(api.close);
        return api;
      }),
      storeProvider.overrideWith((ref) async {
        final db = SlimmDatabase(NativeDatabase.memory());
        await db.customStatement('DROP TABLE channels');
        await db.customStatement('DROP TABLE IF EXISTS channel_categories');
        return MessageStore(db);
      }),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test(
    'channel reorder: a local store failure settles it with an error',
    () async {
      final container = _container(
        (r) => http.Response(
          jsonEncode([
            {
              'id': 'b',
              'name': 'b',
              'kind': 'text',
              'created_at': 0,
              'position': 0,
            },
          ]),
          200,
        ),
      );
      final controller = container.read(
        channelOrderControllerProvider.notifier,
      );
      Object? escaped;
      try {
        await controller.reorder([
          const ChannelOrderGroup(categoryId: null, channelIds: ['b']),
        ]);
      } catch (e) {
        escaped = e;
      }
      final state = container.read(channelOrderControllerProvider);
      expect(
        escaped,
        isNull,
        reason: 'the failure escapes reorder() unhandled',
      );
      expect(state.pendingOrder, isNull, reason: 'pendingOrder stuck');
      expect(state.error, isNotNull, reason: 'no error surfaced');
    },
  );

  test(
    'category reorder: a local store failure settles it with an error',
    () async {
      final container = _container(
        (r) => http.Response(
          jsonEncode({'id': 'c1', 'name': 'c', 'position': 0, 'created_at': 0}),
          200,
        ),
      );
      final controller = container.read(
        categoryOrderControllerProvider.notifier,
      );
      Object? escaped;
      try {
        await controller.reorder(['c1']);
      } catch (e) {
        escaped = e;
      }
      final state = container.read(categoryOrderControllerProvider);
      expect(escaped, isNull);
      expect(state.pendingOrder, isNull);
      expect(state.error, isNotNull);
    },
  );
}
