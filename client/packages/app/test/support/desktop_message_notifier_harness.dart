// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The wiring the desktop message notifier tests share, so each file stays a set of cases.
library;

import 'dart:async';
import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_notification_overrides_controller.dart';
import 'package:slimm_app/src/desktop/providers/desktop_message_notifier.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/push/providers/push_controller.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_platform/testing.dart';
import 'fake_api.dart';
import 'fake_taskbar_attention.dart';

class FakeNotifications implements LocalNotifications {
  final shown = <String>[];
  final channels = <LocalAlertChannel>[];
  final payloads = <String?>[];

  @override
  Future<void> show(
    String text, {
    required LocalAlertChannel channel,
    String? title,
    String? payload,
    int? id,
  }) async {
    shown.add(title == null ? text : '$title: $text');
    payloads.add(payload);
    channels.add(channel);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const notifierTokens = api.TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

api.Message notifierMessage({
  required String id,
  required String authorId,
  String? authorDisplayName,
  required String channelId,
  String content = 'hi',
  bool mentionsMe = false,
}) => api.Message(
  id: id,
  channelId: channelId,
  authorId: authorId,
  authorDisplayName: authorDisplayName ?? authorId,
  seq: 1,
  content: content,
  createdAt: 0,
  editedAt: null,
  mentionsMe: mentionsMe,
);

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

class NotifierSetup {
  NotifierSetup(
    this.container,
    this.events,
    this.notifications,
    this.db,
    this.taskbar,
  );

  final ProviderContainer container;
  final StreamController<api.ServerEvent> events;
  final FakeNotifications notifications;
  final SlimmDatabase db;
  final FakeTaskbarAttention taskbar;

  Future<void> dispose() async {
    container.dispose();
    await events.close();
    await db.close();
  }
}

Future<NotifierSetup> wireNotifier({List<Override> extra = const []}) async {
  final db = SlimmDatabase(NativeDatabase.memory());
  final store = MessageStore(db);
  await store.upsertChannels([
    const api.Channel(
      id: 'group-1',
      name: 'general',
      kind: 'text',
      createdAt: 0,
    ),
  ]);

  final events = StreamController<api.ServerEvent>.broadcast();
  final notifications = FakeNotifications();
  final taskbar = FakeTaskbarAttention();

  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(
        api.SessionStore(tokens: notifierTokens),
      ),
      storeProvider.overrideWith((ref) async => store),
      liveEventsProvider.overrideWithValue(events.stream),
      localNotificationsProvider.overrideWithValue(notifications),
      taskbarAttentionProvider.overrideWithValue(taskbar),
      ...extra,
      mockApiOverride((request) async {
        if (request.url.path.startsWith(
              '/notification-preferences/channels/',
            ) &&
            request.method == 'PUT') {
          final channelId = request.url.pathSegments.last;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return _json({
            'channel_id': channelId,
            'preference': body['preference'],
          });
        }
        if (request.url.path.endsWith('/me')) {
          return _json({
            'id': 'me',
            'username': 'nick',
            'display_name': 'Nick',
            'created_at': 0,
            'permissions': 0,
          });
        }
        return _json(const <Object>[]);
      }),
    ],
  );
  await container.read(channelNotificationOverridesProvider.notifier).refresh();
  container.read(desktopMessageNotifierProvider);

  return NotifierSetup(container, events, notifications, db, taskbar);
}

/// Pushes a message by "me" (never notified) behind whatever the test just
/// sent, then yields until [until] holds - a bounded wait on a condition, not
/// a fixed number of turns: the mention path adds an `await` for the caller's
/// own username that the ordinary path does not have.
Future<void> settleNotifier(
  NotifierSetup setup, {
  bool Function()? until,
}) async {
  setup.events.add(
    api.MessageCreated(
      notifierMessage(id: 'flush', authorId: 'me', channelId: 'group-1'),
    ),
  );
  for (var turn = 0; turn < 50; turn++) {
    await Future<void>.delayed(Duration.zero);
    if (until != null && until()) return;
  }
}
