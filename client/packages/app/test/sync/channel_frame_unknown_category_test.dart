// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A channel frame naming a category this device does not hold, or one whose
/// parent it does not hold, refreshes the listing (decision 0120). Otherwise
/// the channel is drawn under no heading at all, or under the wrong one,
/// until some unrelated refresh happens to run.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/channels/providers/category_nesting.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart'
    show CategoryStore, MessageStore, SlimmDatabase;
import 'package:slimm_platform/testing.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

const _tokens = TokenPair(
  userId: 'alice',
  accessToken: 'access-alice',
  refreshToken: 'refresh-alice',
  accessExpiresAt: 0,
);

Map<String, dynamic> _channel(String categoryId) => {
  'id': 'c-ranked',
  'name': 'ranked',
  'kind': 'text',
  'topic': null,
  'created_at': 1000,
  'category_id': categoryId,
};

Map<String, dynamic> _category(String id, {String? parentId}) => {
  'id': id,
  'name': id,
  'position': 0,
  'created_at': 0,
  'parent_id': parentId,
};

/// Answers the refresh's reads with gamers and cs2, and records what was asked.
({ProviderContainer container, MessageStore store, List<String> paths})
_harness() {
  final db = SlimmDatabase(NativeDatabase.memory());
  final store = MessageStore(db);
  final paths = <String>[];
  http.Response json(Object body) => http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json'},
  );
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore()),
      storeProvider.overrideWith((ref) async => store),
      apiProvider.overrideWith((ref) {
        final api = testApi((request) async {
          paths.add(request.url.path);
          return switch (request.url.path) {
            '/categories' => json([
              _category('gamers'),
              _category('cs2', parentId: 'gamers'),
            ]),
            '/channels' => json([_channel('cs2')]),
            '/read-states' => json(<Object>[]),
            _ => json(<Object>[]),
          };
        }, session: SessionStore(tokens: _tokens));
        ref.onDispose(api.close);
        return api;
      }),
    ],
  );
  addTearDown(container.dispose);
  addTearDown(db.close);
  return (container: container, store: store, paths: paths);
}

Future<void> _apply(ProviderContainer container, Map<String, dynamic> frame) =>
    container
        .read(syncControllerProvider.notifier)
        .applyServerEventForTest(ServerEvent.parse(jsonEncode(frame))!);

void main() {
  test('a channel moved into a category this device never held refreshes '
      'the listing', () async {
    final h = _harness();

    await _apply(h.container, {
      'type': 'channel.updated',
      'channel': _channel('cs2'),
    });

    expect(h.paths, contains('/categories'));
    final held = {for (final c in await h.store.allCategories()) c.id: c};
    expect(held['cs2']?.parentId, 'gamers');
    expect(held, contains('gamers'));
    expect(h.container.read(categoriesNestProvider), isTrue);
  });

  test('a sub-category held without its parent refreshes too', () async {
    final h = _harness();
    await h.store.replaceCategories([
      const ChannelCategory(
        id: 'cs2',
        name: 'cs2',
        position: 0,
        createdAt: 0,
        parentId: 'gamers',
        serverNests: true,
      ),
    ]);

    await _apply(h.container, {
      'type': 'channel.created',
      'channel': _channel('cs2'),
    });

    expect(h.paths, contains('/categories'));
  });

  test('a channel in a category already held makes no request', () async {
    final h = _harness();
    await h.store.replaceCategories([
      const ChannelCategory(
        id: 'gamers',
        name: 'gamers',
        position: 0,
        createdAt: 0,
      ),
      const ChannelCategory(
        id: 'cs2',
        name: 'cs2',
        position: 0,
        createdAt: 0,
        parentId: 'gamers',
        serverNests: true,
      ),
    ]);

    await _apply(h.container, {
      'type': 'channel.updated',
      'channel': _channel('cs2'),
    });

    expect(h.paths, isEmpty);
  });
}
