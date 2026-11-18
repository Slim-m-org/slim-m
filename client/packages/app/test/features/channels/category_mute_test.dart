// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Muting a category: every channel in it and in its sub-categories reads as
/// muted unless it has its own choice, a refused write is put back, and another
/// device's mute arrives live.
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_notification_overrides_controller.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 4102444800000,
);

Channel _channel(String id, String? categoryId) => Channel(
  id: id,
  name: id,
  kind: 'text',
  createdAt: 0,
  position: 0,
  categoryId: categoryId,
  cursor: 4,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
);

final _lobby = _channel('lobby', 'games');
final _snes = _channel('snes', 'retro');
final _news = _channel('news', 'other');

class _Rig {
  final requests = <String>[];
  final List<String> stored;
  bool refuseWrites = false;
  late final MessageStore store;
  late final ProviderContainer container;

  _Rig({this.stored = const []});

  Future<void> start() async {
    store = MessageStore(SlimmDatabase(NativeDatabase.memory()));
    await store.replaceCategories(const [
      api.ChannelCategory(
        id: 'games',
        name: 'Games',
        position: 0,
        createdAt: 0,
      ),
      api.ChannelCategory(
        id: 'retro',
        name: 'Retro',
        position: 0,
        createdAt: 0,
        parentId: 'games',
      ),
      api.ChannelCategory(
        id: 'other',
        name: 'Other',
        position: 1,
        createdAt: 0,
      ),
    ]);
    container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        storeProvider.overrideWith((ref) async => store),
        liveEventsProvider.overrideWithValue(const Stream.empty()),
        mockApiOverride(_answer),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await store.db.close();
    });
    await state.refresh();
  }

  Future<http.Response> _answer(http.Request request) async {
    final path = request.url.path;
    if (request.method != 'GET') requests.add('${request.method} $path');
    if (refuseWrites && request.method != 'GET') {
      return http.Response(jsonEncode({'error': 'no'}), 500);
    }
    if (path == '/notification-preferences/categories') {
      return _json([
        for (final id in stored) {'category_id': id},
      ]);
    }
    if (request.method == 'DELETE') return http.Response('', 204);
    if (request.method == 'PUT' && path.contains('/categories/')) {
      return _json({'category_id': path.split('/').last});
    }
    if (request.method == 'PUT') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      return _json({
        'channel_id': path.split('/').last,
        'preference': body['preference'],
      });
    }
    return _json(const <Object>[]);
  }

  ChannelNotificationOverridesController get state =>
      container.read(channelNotificationOverridesProvider.notifier);

  api.NotificationPreference? effective(Channel channel) => container
      .read(channelNotificationOverridesProvider)
      .effectiveFor(channel);

  /// Lets the category tree reach the controller.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));
}

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  test(
    'muting a category quiets it and its sub-categories, nothing else',
    () async {
      final rig = _Rig();
      await rig.start();

      await rig.state.muteCategory('games');
      await rig.settle();

      expect(rig.requests, ['PUT /notification-preferences/categories/games']);
      expect(rig.effective(_lobby), api.NotificationPreference.nothing);
      expect(rig.effective(_snes), api.NotificationPreference.nothing);
      expect(rig.effective(_news), isNull);

      await rig.state.unmuteCategory('games');
      expect(
        rig.requests.last,
        'DELETE /notification-preferences/categories/games',
      );
      expect(rig.effective(_lobby), isNull);
      expect(rig.effective(_snes), isNull);
    },
  );

  test('a channel of its own choosing beats its category', () async {
    final rig = _Rig(stored: ['games']);
    await rig.start();
    await rig.state.mentionsOnly('lobby');
    await rig.settle();

    expect(rig.effective(_lobby), api.NotificationPreference.mentions);
    expect(rig.effective(_snes), api.NotificationPreference.nothing);
  });

  test('a refused mute is put back', () async {
    final rig = _Rig()..refuseWrites = true;
    await rig.start();

    await expectLater(rig.state.muteCategory('games'), throwsA(anything));

    expect(rig.effective(_lobby), isNull);
    expect(
      rig.container.read(channelNotificationOverridesProvider).mutedCategories,
      isEmpty,
    );
  });

  test('a mute from another device arrives live', () async {
    final rig = _Rig();
    await rig.start();
    final sync = rig.container.read(syncControllerProvider.notifier);

    await sync.applyServerEventForTest(
      const api.CategoryMuteChanged(categoryId: 'retro', muted: true),
    );
    await rig.settle();
    expect(rig.effective(_snes), api.NotificationPreference.nothing);
    expect(rig.effective(_lobby), isNull);

    await sync.applyServerEventForTest(
      const api.CategoryMuteChanged(categoryId: 'retro', muted: false),
    );
    expect(rig.effective(_snes), isNull);
  });
}
