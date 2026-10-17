// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A muted or mentions-only channel neither chimes in-app - the client-side
/// half of "so a muted channel neither chimes nor pushes". `channelEarnsASound`'s
/// own decision logic is covered standalone in `notification_sound_rules_test.dart`;
/// this drives it through the real controller and provider the way
/// `notification_sound_message_test.dart` already does for the account-wide
/// rules, and pins the property that muting never touches unread state,
/// which stays [MessageStore]/[Channel]'s own concern untouched by any of this.
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/audio/notification_sound.dart';
import 'package:slimm_app/src/providers/channel_notification_overrides_controller.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/notification_sound_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_platform/platform.dart';
import 'support/fake_sound_player.dart';

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

api.Message _message({
  required String id,
  required String authorId,
  required String channelId,
  required String content,
}) => api.Message(
  id: id,
  channelId: channelId,
  authorId: authorId,
  authorDisplayName: authorId,
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
  _Setup(this.container, this.events, this.player, this.db);

  final ProviderContainer container;
  final StreamController<api.ServerEvent> events;
  final RecordingSoundPlayer player;
  final SlimmDatabase db;

  Future<void> dispose() async {
    container.dispose();
    await events.close();
    await db.close();
  }
}

/// A container wired at one text channel and one DM, with the PUT/DELETE
/// override routes answered for real so
/// [ChannelNotificationOverridesController] round-trips exactly as it does
/// against the server, the same as `notification_sound_message_test.dart`
/// answers `/me` and `/blocks` for real.
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
    const api.Channel(id: 'dm-1', name: 'Alice', kind: 'dm', createdAt: 0),
  ]);

  final events = StreamController<api.ServerEvent>.broadcast();
  final player = RecordingSoundPlayer();

  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      storeProvider.overrideWith((ref) async => store),
      liveEventsProvider.overrideWithValue(events.stream),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            if (request.url.path == '/me') {
              return _json({
                'id': 'me',
                'username': 'nick',
                'display_name': 'Nick',
                'created_at': 0,
                'permissions': 0,
              });
            }
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
            return _json(const <Object>[]);
          }),
        );
        ref.onDispose(client.close);
        return client;
      }),
      notificationSoundControllerProvider.overrideWith(
        (ref) => NotificationSoundController(ref, player: player),
      ),
    ],
  );
  // Forces creation, and lets both controllers' own startup fetches settle.
  container.read(notificationSoundControllerProvider);
  await container.read(channelNotificationOverridesProvider.notifier).refresh();

  return _Setup(container, events, player, db);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a muted channel plays nothing for an ordinary message', () async {
    final setup = await _wire();
    await setup.container
        .read(channelNotificationOverridesProvider.notifier)
        .mute('group-1');

    setup.events.add(
      api.MessageCreated(
        _message(
          id: 'm1',
          authorId: 'alice',
          channelId: 'group-1',
          content: 'hi everyone',
        ),
      ),
    );
    await pumpEventQueue();

    expect(setup.player.played, isEmpty);
    await setup.dispose();
  });

  test('a muted channel silences even a real mention', () async {
    final setup = await _wire();
    await setup.container
        .read(channelNotificationOverridesProvider.notifier)
        .mute('group-1');

    setup.events.add(
      api.MessageCreated(
        _message(
          id: 'm1',
          authorId: 'alice',
          channelId: 'group-1',
          content: 'hey @nick look',
        ),
      ),
    );
    await pumpEventQueue();

    expect(setup.player.played, isEmpty);
    await setup.dispose();
  });

  test('a mentions-only override skips a plain message but still catches a '
      'mention in the same channel', () async {
    final setup = await _wire();
    await setup.container
        .read(channelNotificationOverridesProvider.notifier)
        .mentionsOnly('group-1');

    setup.events.add(
      api.MessageCreated(
        _message(
          id: 'm1',
          authorId: 'alice',
          channelId: 'group-1',
          content: 'just chatting',
        ),
      ),
    );
    await pumpEventQueue();
    expect(
      setup.player.played,
      isEmpty,
      reason: 'a plain message must not chime under mentions-only',
    );

    setup.events.add(
      api.MessageCreated(
        _message(
          id: 'm2',
          authorId: 'alice',
          channelId: 'group-1',
          content: 'hey @nick look',
        ),
      ),
    );
    await pumpEventQueue();
    expect(setup.player.played, [NotificationSound.mention]);
    await setup.dispose();
  });

  test('muting one channel does not silence an unrelated one', () async {
    final setup = await _wire();
    await setup.container
        .read(channelNotificationOverridesProvider.notifier)
        .mute('group-1');

    setup.events.add(
      api.MessageCreated(
        _message(id: 'm1', authorId: 'alice', channelId: 'dm-1', content: 'hi'),
      ),
    );
    await pumpEventQueue();

    expect(setup.player.played, [NotificationSound.directMessage]);
    await setup.dispose();
  });

  test('clearing a mute restores the chime', () async {
    final setup = await _wire();
    final notifier = setup.container.read(
      channelNotificationOverridesProvider.notifier,
    );
    await notifier.mute('group-1');
    await notifier.clear('group-1');

    setup.events.add(
      api.MessageCreated(
        _message(
          id: 'm1',
          authorId: 'alice',
          channelId: 'group-1',
          content: 'hi everyone',
        ),
      ),
    );
    await pumpEventQueue();

    expect(setup.player.played, [NotificationSound.groupMessage]);
    await setup.dispose();
  });

  /// [NotificationSoundController] never touches [MessageStore] or read
  /// state at all - it only decides whether to call [SoundPlayer.play] - so
  /// muting a channel here cannot be the thing that stops a message being
  /// received or counted unread. The rail's own `unread` computation
  /// (`channel.cursor > channel.lastReadSeq`) and its independence from mute
  /// is covered directly, at the widget that renders it, in
  /// `channel_rail_mute_test.dart`.
  test('a muted channel plays no sound but the event still reaches every '
      'other live-event listener, unfiltered', () async {
    final setup = await _wire();
    await setup.container
        .read(channelNotificationOverridesProvider.notifier)
        .mute('group-1');

    final seen = <api.ServerEvent>[];
    final sub = setup.container.read(liveEventsProvider).listen(seen.add);

    setup.events.add(
      api.MessageCreated(
        _message(
          id: 'm1',
          authorId: 'alice',
          channelId: 'group-1',
          content: 'hi everyone',
        ),
      ),
    );
    await pumpEventQueue();

    expect(setup.player.played, isEmpty);
    expect(
      seen,
      hasLength(1),
      reason:
          'muting is a sound-controller-only gate; the same live event a '
          'read-state or sync listener would consume must still arrive',
    );
    await sub.cancel();
    await setup.dispose();
  });
}
