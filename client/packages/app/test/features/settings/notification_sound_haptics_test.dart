// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [NotificationSoundController]'s haptic half: a message and a call ring
/// fire an [AppHaptics] cue on the same call site the chime does, so a
/// suppressed sound (settings off, own message, a blocked author) suppresses
/// the tick with it, with nothing here re-implementing that gating.
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
import 'package:slimm_app/src/features/members/providers/blocks_controller.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/features/settings/providers/notification_sound_controller.dart';
import 'package:slimm_app/src/features/settings/providers/notification_sound_settings.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/voice/providers/voice_settings_controller.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_platform/platform.dart';
import '../../support/fake_sound_player.dart';

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
  _Setup(this.container, this.events, this.selectionTicks, this.db);

  final ProviderContainer container;
  final StreamController<api.ServerEvent> events;
  final List<int> selectionTicks;
  final SlimmDatabase db;

  Future<void> dispose() async {
    container.dispose();
    await events.close();
    await db.close();
  }
}

/// A container wired at one text channel, with `me` answering as user
/// `me`/username `nick`, and the two haptic cues recorded rather than
/// reaching a real platform channel.
Future<_Setup> _wireMessage() async {
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
  final selectionTicks = <int>[];

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
            if (request.url.path == '/blocks') return _json(const <Object>[]);
            return _json(const <Object>[]);
          }),
        );
        ref.onDispose(client.close);
        return client;
      }),
      notificationSoundControllerProvider.overrideWith(
        (ref) => NotificationSoundController(
          ref,
          player: SilentSoundPlayer(),
          messageHaptic: () => selectionTicks.add(1),
        ),
      ),
    ],
  );
  container.read(notificationSoundControllerProvider);
  await container.read(blocksProvider.notifier).refresh();

  return _Setup(container, events, selectionTicks, db);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('an ordinary group message fires the message haptic', () async {
    final setup = await _wireMessage();
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

    expect(setup.selectionTicks, [1]);
    await setup.dispose();
  });

  test('this device\'s own message fires no haptic, the same gate that '
      'silences its chime', () async {
    final setup = await _wireMessage();
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

    expect(setup.selectionTicks, isEmpty);
    await setup.dispose();
  });

  test('turning message sounds off silences the message haptic too', () async {
    final setup = await _wireMessage();
    setup.container.read(messageSoundSettingsProvider);
    await pumpEventQueue();
    await setup.container
        .read(messageSoundSettingsProvider.notifier)
        .setEnabled(false);
    setup.events.add(
      api.MessageCreated(
        _message(
          id: 'm1',
          authorId: 'alice',
          channelId: 'group-1',
          content: 'hi',
        ),
      ),
    );
    await pumpEventQueue();

    expect(setup.selectionTicks, isEmpty);
    await setup.dispose();
  });

  test('an incoming DM call ring fires the call-ring haptic', () async {
    final callRingTicks = <int>[];
    final events = StreamController<api.ServerEvent>.broadcast();
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        liveEventsProvider.overrideWithValue(events.stream),
        notificationSoundControllerProvider.overrideWith(
          (ref) => NotificationSoundController(
            ref,
            player: SilentSoundPlayer(),
            callRingHaptic: () => callRingTicks.add(1),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(events.close);
    container.read(notificationSoundControllerProvider);
    container.read(voiceSettingsControllerProvider);
    await pumpEventQueue();

    events.add(
      const api.CallRinging(
        channelId: 'dm-1',
        ringId: 'ring-1',
        callerId: 'alice',
      ),
    );
    await pumpEventQueue();

    expect(callRingTicks, [1]);
  });

  test('this device\'s own outgoing ring fires no haptic', () async {
    final callRingTicks = <int>[];
    final events = StreamController<api.ServerEvent>.broadcast();
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        liveEventsProvider.overrideWithValue(events.stream),
        notificationSoundControllerProvider.overrideWith(
          (ref) => NotificationSoundController(
            ref,
            player: SilentSoundPlayer(),
            callRingHaptic: () => callRingTicks.add(1),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(events.close);
    container.read(notificationSoundControllerProvider);
    container.read(voiceSettingsControllerProvider);
    await pumpEventQueue();

    events.add(
      const api.CallRinging(
        channelId: 'dm-1',
        ringId: 'ring-1',
        callerId: 'me',
      ),
    );
    await pumpEventQueue();

    expect(callRingTicks, isEmpty);
  });
}
