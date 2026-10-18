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
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/audio/notification_sound.dart';
import 'package:slimm_app/src/features/members/providers/blocks_controller.dart';
import 'package:slimm_app/src/features/channels/providers/mounted_channels.dart';
import 'package:slimm_app/src/features/settings/providers/ui_sound_settings.dart';
import 'package:slimm_app/src/providers/app_lifecycle.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/features/settings/providers/notification_sound_controller.dart';
import 'package:slimm_app/src/features/settings/providers/notification_sound_settings.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_platform/platform.dart';
import '../../support/fake_sound_player.dart';
import '../../support/fake_api.dart';

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
Future<_Setup> _wire({
  List<String> blocked = const [],
  List<Override> extra = const [],
}) async {
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
      mockApiOverride((request) async {
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
      notificationSoundControllerProvider.overrideWith(
        (ref) => NotificationSoundController(ref, player: player),
      ),
      ...extra,
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

  group('in the channel on screen', () {
    Future<_Setup> viewing({bool focused = true}) async {
      final setup = await _wire(
        extra: [appFocusedProvider.overrideWithValue(focused)],
      );
      setup.container.read(mountedChannelsProvider).register('group-1');
      setup.container.read(uiSoundSettingsProvider);
      await pumpEventQueue();
      return setup;
    }

    void say(_Setup setup, String content) => setup.events.add(
      api.MessageCreated(
        _message(
          id: 'm1',
          authorId: 'alice',
          channelId: 'group-1',
          content: content,
        ),
      ),
    );

    test('a plain message plays the soft cue, never the group chime', () async {
      final setup = await viewing();
      say(setup, 'hello');
      await pumpEventQueue();

      expect(setup.player.played, [NotificationSound.messageReceivedInView]);
      await setup.dispose();
    });

    test('an unfocused window keeps the notification chime', () async {
      final setup = await viewing(focused: false);
      say(setup, 'hello');
      await pumpEventQueue();

      expect(setup.player.played, [NotificationSound.groupMessage]);
      await setup.dispose();
    });

    test('a mention still gets the mention chime', () async {
      final setup = await viewing();
      say(setup, 'hey @nick');
      await pumpEventQueue();

      expect(setup.player.played, [NotificationSound.mention]);
      await setup.dispose();
    });

    test('interface sounds off falls back to the group chime', () async {
      final setup = await viewing();
      await setup.container
          .read(uiSoundSettingsProvider.notifier)
          .setEnabled(false);
      say(setup, 'hello');
      await pumpEventQueue();

      expect(setup.player.played, [NotificationSound.groupMessage]);
      await setup.dispose();
    });

    test('a different channel keeps the group chime', () async {
      final setup = await viewing();
      setup.events.add(
        api.MessageCreated(
          _message(
            id: 'm2',
            authorId: 'alice',
            channelId: 'dm-1',
            content: 'hi',
          ),
        ),
      );
      await pumpEventQueue();

      expect(setup.player.played, [NotificationSound.directMessage]);
      await setup.dispose();
    });
  });
}
