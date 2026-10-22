// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rig the message alert policy suites share: an account, its overrides,
/// blocks and posting rights, served by a fake API.
library;

import 'dart:async';
import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_notification_overrides_controller.dart';
import 'package:slimm_app/src/features/messages/providers/message_alert_policy.dart';
import 'package:slimm_app/src/features/settings/providers/notification_schedule_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_platform/testing.dart';
import 'fake_api.dart';

const alertTokens = api.TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

http.Response alertJson(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

api.Message alertMessage(
  String channelId,
  String content, {
  String? authorId = 'alice',
  String? webhookUsername,
  bool mentionsMe = false,
}) => api.Message(
  id: 'm-${content.hashCode}',
  channelId: channelId,
  authorId: authorId,
  authorDisplayName: authorId,
  seq: 1,
  content: content,
  createdAt: 0,
  editedAt: null,
  webhookUsername: webhookUsername,
  mentionsMe: mentionsMe,
);

/// A wired policy over a fake server. [account] is what `/push/preference`
/// answers, [overrides] what `/notification-preferences/channels` lists, and
/// [parentFails] makes the thread-parent lookup a 500.
class AlertRig {
  AlertRig({
    this.account = 'everything',
    this.accountFails = false,
    this.overrides = const {},
    this.parentFails = false,
  });

  /// Both can change under the policy, like a setting changed on another device.
  String account;
  bool accountFails;

  /// When the schedule says the account is snoozed until, or null for none.
  int? snoozeUntil;
  bool scheduleFails = false;
  int scheduleRequests = 0;

  /// Lookups of this account's own profile, which the policy no longer makes.
  int meRequests = 0;
  final Map<String, String> overrides;
  final bool parentFails;

  /// Channels this account can read but not post in.
  Set<String> readOnly = const {};

  /// Author ids `GET /users` reports as `bot` or `webhook`.
  Map<String, String> automated = const {};

  /// Makes the author lookup a 500, or never answer.
  bool usersFail = false;
  bool usersHang = false;
  int permissionRequests = 0;
  final threadParentRequests = <String>[];

  late final SlimmDatabase db;
  late final ProviderContainer container;

  MessageAlertPolicy get policy => container.read(messageAlertPolicyProvider);

  Future<void> start() async {
    db = SlimmDatabase(NativeDatabase.memory());
    final store = MessageStore(db);
    await store.upsertChannels([
      const api.Channel(
        id: 'group-1',
        name: 'general',
        kind: 'text',
        createdAt: 0,
      ),
      const api.Channel(id: 'dm-1', name: 'Alice', kind: 'dm', createdAt: 0),
      const api.Channel(
        id: 'thread-1',
        name: '',
        kind: 'text',
        createdAt: 0,
        parentMessageId: 'pm1',
      ),
    ]);
    container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(
          api.SessionStore(tokens: alertTokens),
        ),
        storeProvider.overrideWith((ref) async => store),
        mockApiOverride(_answer),
      ],
    );
    // Held alive for the session the way home_shell holds it; unobserved it would refetch on every read.
    container.listen(notificationScheduleProvider, (_, _) {});
    await container
        .read(channelNotificationOverridesProvider.notifier)
        .refresh();
  }

  Future<http.Response> _answer(http.Request request) async {
    final path = request.url.path;
    if (path == '/me') {
      meRequests++;
      return alertJson({
        'id': 'me',
        'username': 'nick',
        'display_name': 'Nick',
        'created_at': 0,
        'permissions': 0,
      });
    }
    if (path == '/push/preference') {
      return accountFails
          ? alertJson({'error': 'boom'}, 500)
          : alertJson({'preference': account});
    }
    if (path == '/notifications/schedule') {
      scheduleRequests++;
      if (scheduleFails) return alertJson({'error': 'boom'}, 500);
      return alertJson({
        'schedule': snoozeUntil == null
            ? null
            : {
                'timezone': 'UTC',
                'days': <Object>[],
                'off_hours_mode': 'mentions_and_dms',
                'snooze_until': snoozeUntil,
                'allowed_user_ids': <String>[],
                'allowed_channel_ids': <String>[],
              },
      });
    }
    if (path == '/notification-preferences/channels') {
      return alertJson([
        for (final e in overrides.entries)
          {'channel_id': e.key, 'preference': e.value},
      ]);
    }
    if (path.startsWith('/channels/') && path.endsWith('/permissions')) {
      permissionRequests++;
      final id = path.split('/')[2];
      return alertJson({'permissions': readOnly.contains(id) ? 2 : 6});
    }
    if (path == '/users') {
      if (usersHang) return Completer<http.Response>().future;
      if (usersFail) return alertJson({'error': 'boom'}, 500);
      final ids = request.url.queryParameters['ids']!.split(',');
      return alertJson([
        for (final id in ids)
          {
            'id': id,
            'username': id,
            'display_name': id,
            'created_at': 0,
            if (automated[id] == 'bot') 'is_bot': true,
            if (automated[id] == 'webhook') 'is_webhook': true,
          },
      ]);
    }
    if (path == '/channels/thread-1/thread-parent') {
      threadParentRequests.add(path);
      if (parentFails) return alertJson({'error': 'boom'}, 500);
      return alertJson({
        'parent_channel_id': 'group-1',
        'parent_message_id': 'pm1',
        'parent_deleted': false,
      });
    }
    return alertJson(const <Object>[]);
  }

  Future<void> dispose() async {
    container.dispose();
    await db.close();
  }
}

Future<bool> alertsFor(AlertRig rig, api.Message message) async =>
    (await rig.policy.evaluate(message)) != null;
