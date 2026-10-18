// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The inbox: channels with a mention or unread messages, mentions first, a
/// tap to the place, "Mark all read", and a friendly empty state.
library;

import 'dart:convert';

import 'package:drift/drift.dart'
    show ApplyInterceptor, QueryExecutor, QueryInterceptor;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_notification_overrides_controller.dart';
import 'package:slimm_app/src/features/messages/providers/inbox.dart';
import 'package:slimm_app/src/features/messages/widgets/inbox_sheet.dart';
import 'package:slimm_app/src/features/messages/widgets/mark_read_action.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

api.Message _message(
  String id,
  String channelId,
  int seq,
  String content, {
  bool mentionsMe = false,
}) => api.Message(
  id: id,
  channelId: channelId,
  authorId: 'ada',
  authorDisplayName: 'Ada',
  seq: seq,
  content: content,
  createdAt: seq * 1000,
  editedAt: null,
  mentionsMe: mentionsMe,
);

class _Rig {
  final db = SlimmDatabase(NativeDatabase.memory());
  late final store = MessageStore(db);
  final posted = <List<String>>[];
  late final ProviderContainer container;
  late final GoRouter router;

  _Rig({Map<String, api.NotificationPreference> muted = const {}}) {
    SharedPreferences.setMockInitialValues({});
    container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        storeProvider.overrideWith((ref) async => store),
        liveEventsProvider.overrideWithValue(const Stream.empty()),
        preferencesProvider.overrideWith(
          (ref) => SharedPreferences.getInstance(),
        ),
        channelNotificationOverridesProvider.overrideWith(
          (ref) => _Muted(ref, muted),
        ),
        mockApiOverride((request) async {
          if (request.url.path != '/read-states/read') {
            return http.Response('{}', 404);
          }
          final ids = (jsonDecode(request.body)['channel_ids'] as List)
              .cast<String>();
          posted.add(ids);
          return http.Response(
            jsonEncode([
              for (final id in ids)
                {
                  'channel_id': id,
                  'last_read_seq': 99,
                  'unread': 0,
                  'manually_unread': false,
                },
            ]),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      ],
    );
    router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, _) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showInboxSheet(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
        GoRoute(
          path: '/channels/:id',
          builder: (_, state) => Text('at ${state.pathParameters['id']}'),
        ),
      ],
    );
  }

  Future<void> seed() async {
    await store.upsertChannels(const [
      api.Channel(id: 'gen', name: 'general', kind: 'text', createdAt: 1),
      api.Channel(id: 'dev', name: 'dev', kind: 'text', createdAt: 2),
      api.Channel(id: 'quiet', name: 'quiet', kind: 'text', createdAt: 3),
    ]);
    await store.applyMessage(_message('m1', 'gen', 1, 'lunch at noon?'));
    await store.applyMessage(
      _message('m2', 'dev', 1, 'ship it @self', mentionsMe: true),
    );
    await store.applyMessage(_message('m3', 'dev', 2, 'and then some'));
  }

  Future<void> open(WidgetTester tester) async {
    addTearDown(container.dispose);
    addTearDown(db.close);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: buildTheme(Brightness.light, AppTokens.light),
          routerConfig: router,
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }
}

class _SelectCounter extends QueryInterceptor {
  int selects = 0;

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor inner,
    String statement,
    List<Object?> args,
  ) {
    selects++;
    return inner.runSelect(statement, args);
  }
}

Future<void> _seedMany(MessageStore store, int count) async {
  await store.upsertChannels([
    for (var i = 0; i < count; i++)
      api.Channel(id: 'c$i', name: 'c$i', kind: 'text', createdAt: i),
  ]);
  for (var i = 0; i < count; i++) {
    await store.applyMessage(_message('m$i', 'c$i', 1, 'hello $i'));
  }
}

class _Muted extends ChannelNotificationOverridesController {
  _Muted(super.ref, Map<String, api.NotificationPreference> byChannel) {
    state = ChannelNotificationOverridesState(
      byChannel: byChannel,
      settled: true,
    );
  }
}

void main() {
  testWidgets('lists the mention first, then the unread channel', (
    tester,
  ) async {
    final rig = _Rig();
    await tester.runAsync(rig.seed);
    await rig.open(tester);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();

    final mention = tester.getTopLeft(find.text('ship it @self'));
    final unread = tester.getTopLeft(find.text('lunch at noon?'));
    expect(mention.dy, lessThan(unread.dy));
    expect(find.text('Inbox'), findsOneWidget);
  });

  testWidgets('a muted channel without a mention is left out', (tester) async {
    final rig = _Rig(muted: {'gen': api.NotificationPreference.nothing});
    await tester.runAsync(rig.seed);
    await rig.open(tester);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();

    expect(find.text('lunch at noon?'), findsNothing);
    expect(find.text('ship it @self'), findsOneWidget);
  });

  testWidgets('an unread row opens its channel', (tester) async {
    final rig = _Rig();
    await tester.runAsync(rig.seed);
    await rig.open(tester);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();

    await tester.tap(find.text('lunch at noon?'));
    await tester.pumpAndSettle();

    expect(find.text('at gen'), findsOneWidget);
  });

  testWidgets('mark all read clears the list and says it is caught up', (
    tester,
  ) async {
    final rig = _Rig();
    await tester.runAsync(rig.seed);
    await rig.open(tester);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Mark all read'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(rig.posted.single, unorderedEquals(['gen', 'dev']));
    expect(find.text('You are all caught up.'), findsOneWidget);
  });

  testWidgets('mark all read covers every unread channel, past the list cap', (
    tester,
  ) async {
    final rig = _Rig();
    await tester.runAsync(() => _seedMany(rig.store, inboxLimit + 50));
    await rig.open(tester);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Mark all read'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();

    expect(rig.posted.expand((b) => b).toSet(), hasLength(inboxLimit + 50));
  });

  test(
    'building the inbox reads messages in one query, not one per channel',
    () async {
      final counter = _SelectCounter();
      final db = SlimmDatabase(NativeDatabase.memory().interceptWith(counter));
      addTearDown(db.close);
      final store = MessageStore(db);
      await _seedMany(store, 40);
      final channels = await store.allChannels();

      counter.selects = 0;
      final entries = await buildInbox(
        store,
        channels,
        const ChannelNotificationOverridesState(byChannel: {}, settled: true),
      );

      expect(entries, hasLength(40));
      expect(entries.every((e) => e.message != null), isTrue);
      expect(counter.selects, 1);
    },
  );

  test('marking more than 200 channels read goes out 200 at a time', () async {
    final rig = _Rig();
    addTearDown(rig.container.dispose);
    addTearDown(rig.db.close);

    await markChannelsRead(rig.container, [
      for (var i = 0; i < 450; i++) 'c$i',
    ]);

    expect(rig.posted.map((b) => b.length), [200, 200, 50]);
  });

  test(
    'buildInbox keeps a mention in a channel that only allows mentions',
    () async {
      final rig = _Rig();
      await rig.seed();
      const overrides = ChannelNotificationOverridesState(
        byChannel: {
          'dev': api.NotificationPreference.mentions,
          'gen': api.NotificationPreference.mentions,
        },
        settled: true,
      );

      final entries = await buildInbox(
        rig.store,
        await rig.store.allChannels(),
        overrides,
      );

      expect(entries.map((e) => e.channel.id), ['dev']);
      expect(entries.single.message?.id, 'm2');
      await rig.db.close();
    },
  );
}
