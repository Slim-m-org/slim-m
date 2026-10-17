// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [NotificationSoundController]'s message half, wired through real
/// providers with a fake [SoundPlayer] recording what played - the pure
/// decision rules themselves are covered without any of this in
/// `notification_sound_rules_test.dart`.
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
import 'package:slimm_app/src/providers/blocks_controller.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/notification_sound_controller.dart';
import 'package:slimm_app/src/providers/notification_sound_settings.dart';
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
  required String? authorId,
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

/// A container wired at two channels - a DM and a text channel - with `me`
/// answering as user `me`/username `nick`, and [blocked] as the server's
/// answer to `GET /blocks`.
Future<_Setup> _wire({List<String> blocked = const []}) async {
  final db = SlimmDatabase(NativeDatabase.memory());
  final store = MessageStore(db);
  await store.upsertChannels([
    const api.Channel(id: 'dm-1', name: 'Alice', kind: 'dm', createdAt: 0),
    const api.Channel(
      id: 'group-1',
      name: 'general',
      kind: 'text',
      createdAt: 0,
    ),
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
            if (request.url.path == '/blocks') return _json(blocked);
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
  // Forces creation, and lets the block-list fetch (if any) settle.
  container.read(notificationSoundControllerProvider);
  await container.read(blocksProvider.notifier).refresh();

  return _Setup(container, events, player, db);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a DM message plays the direct-message chime', () async {
    final setup = await _wire();
    setup.events.add(
      api.MessageCreated(
        _message(id: 'm1', authorId: 'alice', channelId: 'dm-1', content: 'hi'),
      ),
    );
    await pumpEventQueue();

    expect(setup.player.played, [NotificationSound.directMessage]);
    await setup.dispose();
  });

  test('an ordinary group message plays the group-message chime', () async {
    final setup = await _wire();
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

  test(
    'a group message mentioning this user plays the mention chime',
    () async {
      final setup = await _wire();
      setup.events.add(
        api.MessageCreated(
          _message(
            id: 'm1',
            authorId: 'alice',
            channelId: 'group-1',
            content: 'hey @nick look at this',
          ),
        ),
      );
      await pumpEventQueue();

      expect(setup.player.played, [NotificationSound.mention]);
      await setup.dispose();
    },
  );

  test('this device\'s own message plays nothing', () async {
    final setup = await _wire();
    setup.events.add(
      api.MessageCreated(
        _message(
          id: 'm1',
          authorId: 'me',
          channelId: 'group-1',
          content: 'sent by me',
        ),
      ),
    );
    await pumpEventQueue();

    expect(setup.player.played, isEmpty);
    await setup.dispose();
  });

  test('a message from a blocked author plays nothing', () async {
    final setup = await _wire(blocked: ['alice']);
    setup.events.add(
      api.MessageCreated(
        _message(id: 'm1', authorId: 'alice', channelId: 'dm-1', content: 'hi'),
      ),
    );
    await pumpEventQueue();

    expect(setup.player.played, isEmpty);
    await setup.dispose();
  });

  test('turning message sounds off silences a real message', () async {
    final setup = await _wire();
    // Lets the controller's own async load settle before setEnabled races it.
    setup.container.read(messageSoundSettingsProvider);
    await pumpEventQueue();
    await setup.container
        .read(messageSoundSettingsProvider.notifier)
        .setEnabled(false);
    setup.events.add(
      api.MessageCreated(
        _message(id: 'm1', authorId: 'alice', channelId: 'dm-1', content: 'hi'),
      ),
    );
    await pumpEventQueue();

    expect(setup.player.played, isEmpty);
    await setup.dispose();
  });
}
