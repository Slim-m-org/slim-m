// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one gate the chime and the desktop banner share: a message alerts only
/// if the preference that applies to it allows it. That preference is the
/// channel's own override, else a thread's parent channel's, else the
/// account's, the order the server resolves it in for push.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/blocks_controller.dart';
import 'package:slimm_app/src/providers/channel_notification_overrides_controller.dart';
import 'package:slimm_app/src/providers/message_alert_policy.dart';
import 'package:slimm_app/src/providers/notification_schedule_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

api.Message _message(
  String channelId,
  String content, {
  String? authorId = 'alice',
}) => api.Message(
  id: 'm-${content.hashCode}',
  channelId: channelId,
  authorId: authorId,
  authorDisplayName: authorId,
  seq: 1,
  content: content,
  createdAt: 0,
  editedAt: null,
);

/// A wired policy over a fake server. [account] is what `/push/preference`
/// answers, [overrides] what `/notification-preferences/channels` lists, and
/// [parentFails] makes the thread-parent lookup a 500.
class _Rig {
  _Rig({
    this.account = 'everything',
    this.accountFails = false,
    this.overrides = const {},
    this.parentFails = false,
  });

  /// Both can change under the policy, like a setting changed on another device.
  String account;
  bool accountFails;

  /// The names of the roles this account holds, as its own profile lists them.
  List<String> roles = const [];

  /// When the schedule says the account is snoozed until, or null for none.
  int? snoozeUntil;
  bool scheduleFails = false;
  int scheduleRequests = 0;

  /// Lookups of this account's own profile, and whether they are refused.
  int meRequests = 0;
  bool meFails = false;
  final Map<String, String> overrides;
  final bool parentFails;
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
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        storeProvider.overrideWith((ref) async => store),
        apiProvider.overrideWith((ref) {
          final client = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient(_answer),
          );
          ref.onDispose(client.close);
          return client;
        }),
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
      if (meFails) return _json({'error': 'slow down'}, 429);
      return _json({
        'id': 'me',
        'username': 'nick',
        'display_name': 'Nick',
        'created_at': 0,
        'permissions': 0,
      });
    }
    if (path == '/users/me') {
      return _json({
        'id': 'me',
        'username': 'nick',
        'display_name': 'Nick',
        'created_at': 0,
        'roles': roles,
      });
    }
    if (path == '/push/preference') {
      return accountFails
          ? _json({'error': 'boom'}, 500)
          : _json({'preference': account});
    }
    if (path == '/notifications/schedule') {
      scheduleRequests++;
      if (scheduleFails) return _json({'error': 'boom'}, 500);
      return _json({
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
      return _json([
        for (final e in overrides.entries)
          {'channel_id': e.key, 'preference': e.value},
      ]);
    }
    if (path == '/channels/thread-1/thread-parent') {
      threadParentRequests.add(path);
      if (parentFails) return _json({'error': 'boom'}, 500);
      return _json({
        'parent_channel_id': 'group-1',
        'parent_message_id': 'pm1',
        'parent_deleted': false,
      });
    }
    return _json(const <Object>[]);
  }

  Future<void> dispose() async {
    container.dispose();
    await db.close();
  }
}

Future<bool> _alerts(_Rig rig, api.Message message) async =>
    (await rig.policy.evaluate(message)) != null;

void main() {
  late _Rig rig;

  Future<void> wire(_Rig next) async {
    rig = next;
    await rig.start();
    addTearDown(rig.dispose);
  }

  group('the account preference', () {
    test('nothing silences a plain group message', () async {
      await wire(_Rig(account: 'nothing'));

      expect(await _alerts(rig, _message('group-1', 'hi all')), isFalse);
    });

    test(
      'mentions silences a plain message and lets a mention through',
      () async {
        await wire(_Rig(account: 'mentions'));

        expect(await _alerts(rig, _message('group-1', 'hi all')), isFalse);
        expect(await _alerts(rig, _message('group-1', 'hi @nick')), isTrue);
      },
    );

    test('everything lets a plain message through', () async {
      await wire(_Rig());

      expect(await _alerts(rig, _message('group-1', 'hi all')), isTrue);
    });

    test('mentions still lets a direct message through', () async {
      await wire(_Rig(account: 'mentions'));

      final alert = await rig.policy.evaluate(_message('dm-1', 'hello'));

      expect(alert?.isDm, isTrue);
    });

    test('an unreadable preference silences nothing', () async {
      await wire(_Rig(account: 'nothing', accountFails: true));

      expect(await _alerts(rig, _message('group-1', 'hi all')), isTrue);
    });
  });

  group('a channel override', () {
    test('beats an account that would allow it', () async {
      await wire(_Rig(overrides: {'group-1': 'nothing'}));

      expect(await _alerts(rig, _message('group-1', 'hi all')), isFalse);
    });

    test('beats an account that would silence it', () async {
      await wire(_Rig(account: 'nothing', overrides: {'group-1': 'mentions'}));

      expect(await _alerts(rig, _message('group-1', 'hi @nick')), isTrue);
    });
  });

  group('a thread', () {
    test('follows a muted parent channel', () async {
      await wire(_Rig(overrides: {'group-1': 'nothing'}));

      expect(await _alerts(rig, _message('thread-1', 'a reply')), isFalse);
    });

    test('keeps its own override over its parent\'s', () async {
      await wire(
        _Rig(overrides: {'group-1': 'nothing', 'thread-1': 'mentions'}),
      );

      expect(await _alerts(rig, _message('thread-1', 'hey @nick')), isTrue);
      expect(await _alerts(rig, _message('thread-1', 'a reply')), isFalse);
    });

    test('follows the account when it has no parent override', () async {
      await wire(_Rig(account: 'nothing'));

      expect(await _alerts(rig, _message('thread-1', 'a reply')), isFalse);
    });

    test('follows the account when the parent cannot be looked up', () async {
      await wire(_Rig(overrides: {'group-1': 'nothing'}, parentFails: true));

      expect(await _alerts(rig, _message('thread-1', 'a reply')), isTrue);
    });

    test('asks for its parent once', () async {
      await wire(_Rig());

      await rig.policy.evaluate(_message('thread-1', 'one'));
      await rig.policy.evaluate(_message('thread-1', 'two'));

      expect(rig.threadParentRequests, hasLength(1));
    });
  });

  group('who the message is from', () {
    test('someone blocked never alerts', () async {
      await wire(_Rig());
      await rig.container.read(blocksProvider.notifier).block('pest');

      expect(
        await _alerts(rig, _message('group-1', 'hi', authorId: 'pest')),
        isFalse,
      );
    });

    test('a deleted account never alerts', () async {
      await wire(_Rig());

      expect(
        await _alerts(rig, _message('group-1', 'hi', authorId: null)),
        isFalse,
      );
    });

    test('yourself never alerts', () async {
      await wire(_Rig());

      expect(
        await _alerts(rig, _message('group-1', 'hi', authorId: 'me')),
        isFalse,
      );
    });
  });

  group('what was set on another device', () {
    late Duration originalMaxAge;

    setUp(() {
      originalMaxAge = alertStateMaxAge;
      alertStateMaxAge = const Duration(milliseconds: 40);
    });
    tearDown(() => alertStateMaxAge = originalMaxAge);

    Future<void> pastMaxAge() =>
        Future<void>.delayed(const Duration(milliseconds: 80));

    test('a snooze is honoured once the schedule is stale', () async {
      await wire(_Rig());
      expect(await _alerts(rig, _message('group-1', 'hi all')), isTrue);

      rig.snoozeUntil = DateTime.now().millisecondsSinceEpoch + 3600 * 1000;
      await pastMaxAge();

      expect(await _alerts(rig, _message('group-1', 'hi all')), isFalse);
    });

    test('a fresh schedule is not asked for again', () async {
      await wire(_Rig());
      await rig.policy.evaluate(_message('group-1', 'one'));
      await rig.policy.evaluate(_message('group-1', 'two'));

      expect(rig.scheduleRequests, 1);
    });

    test('a schedule that failed to load is asked for again', () async {
      final failing = _Rig()..scheduleFails = true;
      await wire(failing);
      await rig.policy.evaluate(_message('group-1', 'one'));

      rig
        ..scheduleFails = false
        ..snoozeUntil = DateTime.now().millisecondsSinceEpoch + 3600 * 1000;

      expect(await _alerts(rig, _message('group-1', 'two')), isFalse);
    });

    test('a changed account preference is honoured once it is stale', () async {
      await wire(_Rig());
      expect(await _alerts(rig, _message('group-1', 'hi all')), isTrue);

      rig.account = 'nothing';
      await pastMaxAge();

      expect(await _alerts(rig, _message('group-1', 'hi all')), isFalse);
    });
  });

  group('a mention that is not the username', () {
    test('@everyone gets through a channel narrowed to mentions', () async {
      await wire(_Rig(overrides: {'group-1': 'mentions'}));

      expect(
        await _alerts(rig, _message('group-1', '@everyone standup')),
        isTrue,
      );
      expect(await _alerts(rig, _message('group-1', 'quick q @here')), isTrue);
    });

    test('a role the account holds does too', () async {
      final holder = _Rig(overrides: {'group-1': 'mentions'})
        ..roles = ['Core Team'];
      await wire(holder);

      expect(
        await _alerts(rig, _message('group-1', 'ping @[Core Team]')),
        isTrue,
      );
    });

    test('a role it does not hold stays quiet', () async {
      await wire(_Rig(overrides: {'group-1': 'mentions'}));

      expect(
        await _alerts(rig, _message('group-1', 'ping @[Core Team]')),
        isFalse,
      );
    });

    test('an unreadable profile costs only the role mentions', () async {
      await wire(_Rig(overrides: {'group-1': 'mentions'}));

      expect(await _alerts(rig, _message('group-1', 'hi @nick')), isTrue);
    });
  });

  group('looking up this account', () {
    test('a burst of messages shares one lookup', () async {
      await wire(_Rig(overrides: {'group-1': 'mentions'}));

      await Future.wait([
        for (var i = 0; i < 10; i++) _alerts(rig, _message('group-1', 'm $i')),
      ]);

      expect(rig.meRequests, 1);
    });

    test('a refused lookup is not retried for every message', () async {
      await wire(_Rig(overrides: {'group-1': 'mentions'})..meFails = true);

      for (var i = 0; i < 5; i++) {
        await _alerts(rig, _message('group-1', 'hi @nick $i'));
      }

      expect(rig.meRequests, 1);
    });

    test('a refused lookup is tried again once the wait passes', () async {
      final saved = selfLookupRetryAfter;
      selfLookupRetryAfter = Duration.zero;
      addTearDown(() => selfLookupRetryAfter = saved);
      await wire(_Rig(overrides: {'group-1': 'mentions'})..meFails = true);

      expect(await _alerts(rig, _message('group-1', 'hi @nick')), isFalse);
      rig.meFails = false;

      expect(await _alerts(rig, _message('group-1', 'hi @nick')), isTrue);
      expect(rig.meRequests, 2);
    });
  });
}
