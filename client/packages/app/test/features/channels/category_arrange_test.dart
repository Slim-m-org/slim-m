// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A server that nests categories (decision 0120) takes a whole arrangement
/// in one `PUT /categories/order`, so a refusal reverts cleanly instead of
/// leaving some categories moved; an older one keeps the per-category PATCH.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' hide Channel;
import 'package:slimm_app/src/features/channels/providers/category_nesting.dart';
import 'package:slimm_app/src/features/channels/providers/channel_order_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/fake_api.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, dynamic> _json(String id, int position, {String? parentId}) => {
  'id': id,
  'name': id,
  'position': position,
  'created_at': 0,
  'parent_id': parentId,
};

final _arrangement = [
  const CategoryOrderGroup(parentId: null, categoryIds: ['gamers']),
  const CategoryOrderGroup(parentId: 'gamers', categoryIds: ['cs2', 'music']),
];

({ProviderContainer container, List<http.Request> requests}) _setup(
  http.Response Function(http.Request) answer, {
  bool nests = true,
}) {
  final requests = <http.Request>[];
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      categoriesNestProvider.overrideWith((ref) => nests),
      mockApiOverride((request) async {
        requests.add(request);
        return answer(request);
      }),
      storeProvider.overrideWith((ref) async {
        final db = SlimmDatabase(NativeDatabase.memory());
        ref.onDispose(db.close);
        final store = MessageStore(db);
        await store.replaceCategories([
          const ChannelCategory(
            id: 'gamers',
            name: 'gamers',
            position: 0,
            createdAt: 0,
          ),
          const ChannelCategory(
            id: 'music',
            name: 'music',
            position: 1,
            createdAt: 0,
          ),
          const ChannelCategory(
            id: 'cs2',
            name: 'cs2',
            position: 0,
            createdAt: 0,
            parentId: 'gamers',
          ),
        ]);
        return store;
      }),
    ],
  );
  addTearDown(container.dispose);
  return (container: container, requests: requests);
}

void main() {
  test(
    'one request carries the whole tree, and the answer is stored',
    () async {
      final s = _setup(
        (_) => http.Response(
          jsonEncode([
            _json('gamers', 0),
            _json('cs2', 0, parentId: 'gamers'),
            _json('music', 1, parentId: 'gamers'),
          ]),
          200,
        ),
      );

      await s.container
          .read(categoryOrderControllerProvider.notifier)
          .arrange(_arrangement);

      expect(s.requests, hasLength(1));
      expect(s.requests.single.method, 'PUT');
      expect(s.requests.single.url.path, '/categories/order');
      expect(jsonDecode(s.requests.single.body), {
        'groups': [
          {
            'parent_id': null,
            'category_ids': ['gamers'],
          },
          {
            'parent_id': 'gamers',
            'category_ids': ['cs2', 'music'],
          },
        ],
      });
      final store = await s.container.read(storeProvider.future);
      final rows = {for (final r in await store.allCategories()) r.id: r};
      expect(rows['music']!.parentId, 'gamers');
      expect(s.container.read(categoryOrderControllerProvider).error, isNull);
    },
  );

  test(
    'a refused third level is held for the rail and nothing moves',
    () async {
      final s = _setup(
        (_) => http.Response(jsonEncode({'error': 'too deep'}), 409),
      );
      final controller = s.container.read(
        categoryOrderControllerProvider.notifier,
      );

      final pending = controller.arrange(_arrangement);
      expect(
        s.container.read(categoryOrderControllerProvider).pendingOrder,
        same(_arrangement),
      );
      await pending;

      final state = s.container.read(categoryOrderControllerProvider);
      expect(state.pendingOrder, isNull);
      expect(state.error, contains('Could not reorder categories'));
      final store = await s.container.read(storeProvider.future);
      final rows = {for (final r in await store.allCategories()) r.id: r};
      expect(rows['music']!.parentId, isNull);
    },
  );

  test('a server that does not nest gets one PATCH per moved top-level '
      'category', () async {
    final s = _setup(
      (request) => http.Response(
        jsonEncode(_json(request.url.pathSegments.last, 0)),
        200,
      ),
      nests: false,
    );

    await s.container.read(categoryOrderControllerProvider.notifier).arrange(
      const [
        CategoryOrderGroup(parentId: null, categoryIds: ['music', 'gamers']),
      ],
    );

    expect(s.requests.map((r) => r.method).toSet(), {'PATCH'});
    expect(s.requests.map((r) => r.url.path).toSet(), {
      '/categories/music',
      '/categories/gamers',
    });
  });

  test('moving into a parent is one PATCH carrying parent_id', () async {
    final s = _setup(
      (_) =>
          http.Response(jsonEncode(_json('music', 1, parentId: 'gamers')), 200),
    );

    await s.container
        .read(categoryOrderControllerProvider.notifier)
        .move('music', 'gamers');

    expect(s.requests.single.method, 'PATCH');
    expect(jsonDecode(s.requests.single.body), {'parent_id': 'gamers'});
    final store = await s.container.read(storeProvider.future);
    final rows = {for (final r in await store.allCategories()) r.id: r};
    expect(rows['music']!.parentId, 'gamers');
  });
}
