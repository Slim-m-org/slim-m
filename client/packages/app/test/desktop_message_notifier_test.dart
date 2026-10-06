// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The desktop live-message notifier turns an incoming socket message into an
/// OS notification, but only for someone else's message that arrives while the
/// window is not in the foreground. Own messages, a focused window, and a
/// channel the override quietens are each silent. The override half runs
/// through the real controller, and covers mentions-only as well as mute:
/// this path used to read only the mute, so a channel narrowed to mentions
/// still raised a banner for every ordinary message while the chime beside
/// it correctly stayed silent.
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/channel_notification_overrides_controller.dart';
import 'package:slimm_app/src/providers/blocks_controller.dart';
import 'package:slimm_app/src/providers/desktop_message_notifier.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/push_controller.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_platform/platform.dart';

class _FakeNotifications implements LocalNotifications {
  final shown = <String>[];
  final channels = <LocalAlertChannel>[];

  @override
  Future<void> show(String text, {required LocalAlertChannel channel}) async {
    shown.add(text);
    channels.add(channel);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

api.Message _message({
  required String id,
  required String authorId,
  String? authorDisplayName,
  required String channelId,
  String content = 'hi',
}) => api.Message(
  id: id,
  channelId: channelId,
  authorId: authorId,
  authorDisplayName: authorDisplayName ?? authorId,
  seq: 1,
  content: content,
  createdAt: 0,
  editedAt: null,
);

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

class _Setup {
  _Setup(this.container, this.events, this.notifications, this.db);

  final ProviderContainer container;
  final StreamController<api.ServerEvent> events;
  final _FakeNotifications notifications;
  final SlimmDatabase db;

  Future<void> dispose() async {
    container.dispose();
    await events.close();
    await db.close();
  }
}

Future<_Setup> _wire() async {
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
  final notifications = _FakeNotifications();

  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      storeProvider.overrideWith((ref) async => store),
      liveEventsProvider.overrideWithValue(events.stream),
      localNotificationsProvider.overrideWithValue(notifications),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
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
        );
        ref.onDispose(client.close);
        return client;
      }),
    ],
  );
  await container.read(channelNotificationOverridesProvider.notifier).refresh();
  container.read(desktopMessageNotifierProvider);

  return _Setup(container, events, notifications, db);
}

/// Pushes a message by "me" (never notified) behind whatever the test just
/// sent, then yields until [until] holds - a bounded wait on a condition, not
/// a fixed number of turns: the mention path adds an `await` for the caller's
/// own username that the ordinary path does not have.
Future<void> _settle(_Setup setup, {bool Function()? until}) async {
  setup.events.add(
    api.MessageCreated(
      _message(id: 'flush', authorId: 'me', channelId: 'group-1'),
    ),
  );
  for (var turn = 0; turn < 50; turn++) {
    await Future<void>.delayed(Duration.zero);
    if (until != null && until()) return;
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('backgrounded, another author: shows a named notification', () async {
    if (!isDesktopHost) return;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    final setup = await _wire();

    setup.events.add(
      api.MessageCreated(
        _message(
          id: 'm1',
          authorId: 'alice',
          authorDisplayName: 'Alice',
          channelId: 'group-1',
        ),
      ),
    );
    await _settle(setup);

    expect(setup.notifications.shown, ['New message from Alice']);
    await setup.dispose();
  });

  test('own message is never notified back to me', () async {
    if (!isDesktopHost) return;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    final setup = await _wire();

    setup.events.add(
      api.MessageCreated(
        _message(id: 'm1', authorId: 'me', channelId: 'group-1'),
      ),
    );
    await _settle(setup);

    expect(setup.notifications.shown, isEmpty);
    await setup.dispose();
  });

  test('after signing in as someone else, "me" is the new account', () async {
    // The account id used to be captured once at bootstrap and never again.
    if (!isDesktopHost) return;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    final setup = await _wire();
    setup.container
        .read(sessionProvider)
        .set(
          const api.TokenPair(
            userId: 'someone-new',
            accessToken: 'access2',
            refreshToken: 'refresh2',
            accessExpiresAt: 0,
          ),
        );

    setup.events.add(
      api.MessageCreated(
        _message(id: 'm1', authorId: 'someone-new', channelId: 'group-1'),
      ),
    );
    setup.events.add(
      api.MessageCreated(
        _message(
          id: 'm2',
          authorId: 'me',
          authorDisplayName: 'Old Me',
          channelId: 'group-1',
        ),
      ),
    );
    await _settle(setup);

    // Not exact: _settle's flush is by the old "me", who may now notify too.
    expect(setup.notifications.shown, contains('New message from Old Me'));
    expect(
      setup.notifications.shown.where((t) => t.contains('someone-new')),
      isEmpty,
      reason: 'the account signed in now must never be notified about itself',
    );
    await setup.dispose();
  });

  test('a focused window shows nothing', () async {
    if (!isDesktopHost) return;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final setup = await _wire();

    setup.events.add(
      api.MessageCreated(
        _message(id: 'm1', authorId: 'alice', channelId: 'group-1'),
      ),
    );
    await _settle(setup);

    expect(setup.notifications.shown, isEmpty);
    await setup.dispose();
  });

  test('a muted channel stays silent', () async {
    if (!isDesktopHost) return;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    final setup = await _wire();
    await setup.container
        .read(channelNotificationOverridesProvider.notifier)
        .mute('group-1');

    setup.events.add(
      api.MessageCreated(
        _message(id: 'm1', authorId: 'alice', channelId: 'group-1'),
      ),
    );
    await _settle(setup);

    expect(setup.notifications.shown, isEmpty);
    await setup.dispose();
  });

  test(
    'a mentions-only channel stays silent for an ordinary message',
    () async {
      if (!isDesktopHost) return;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      final setup = await _wire();
      await setup.container
          .read(channelNotificationOverridesProvider.notifier)
          .mentionsOnly('group-1');

      setup.events.add(
        api.MessageCreated(
          _message(id: 'm1', authorId: 'alice', channelId: 'group-1'),
        ),
      );
      await _settle(setup);

      expect(
        setup.notifications.shown,
        isEmpty,
        reason: 'the chime already refused this message; the banner did not',
      );
      await setup.dispose();
    },
  );

  test('a real mention in a mentions-only channel still notifies, as a '
      'mention', () async {
    if (!isDesktopHost) return;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    final setup = await _wire();
    await setup.container
        .read(channelNotificationOverridesProvider.notifier)
        .mentionsOnly('group-1');

    setup.events.add(
      api.MessageCreated(
        _message(
          id: 'm1',
          authorId: 'alice',
          authorDisplayName: 'Alice',
          channelId: 'group-1',
          content: 'hey @nick look',
        ),
      ),
    );
    await _settle(setup, until: () => setup.notifications.shown.isNotEmpty);

    expect(setup.notifications.shown, ['New message from Alice']);
    expect(
      setup.notifications.channels,
      [LocalAlertChannel.mentions],
      reason:
          'every banner used to be filed under messages, so the OS\'s '
          'own per-kind control for mentions never applied',
    );
    await setup.dispose();
  });

  test('a blocked author is never bannered', () async {
    if (!isDesktopHost) return;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    final setup = await _wire();
    await setup.container.read(blocksProvider.notifier).block('pest');

    setup.events.add(
      api.MessageCreated(
        _message(
          id: 'm1',
          authorId: 'pest',
          authorDisplayName: 'Pest',
          channelId: 'group-1',
        ),
      ),
    );
    await _settle(setup);

    expect(setup.notifications.shown, isEmpty);
    await setup.dispose();
  });

  test('a message from a deleted account is not bannered', () async {
    if (!isDesktopHost) return;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    final setup = await _wire();

    setup.events.add(
      const api.MessageCreated(
        api.Message(
          id: 'm1',
          channelId: 'group-1',
          authorId: null,
          authorDisplayName: 'Deleted',
          seq: 1,
          content: 'hi',
          createdAt: 0,
          editedAt: null,
        ),
      ),
    );
    await _settle(setup);

    expect(setup.notifications.shown, isEmpty);
    await setup.dispose();
  });
}
