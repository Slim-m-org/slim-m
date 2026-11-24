// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Session-scoped state that a sign-out must hand to the next account empty.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/category_nesting.dart';
import 'package:slimm_app/src/features/channels/providers/last_text_channel.dart';
import 'package:slimm_app/src/features/channels/providers/slow_mode_controller.dart';
import 'package:slimm_app/src/features/channels/providers/threads.dart';
import 'package:slimm_app/src/features/emoji/providers/recent_emoji.dart';
import 'package:slimm_app/src/features/members/providers/activity_sharing_settings.dart';
import 'package:slimm_app/src/features/palette/providers/conversation_search_memory.dart';
import 'package:slimm_app/src/features/messages/providers/message_search_query.dart';
import 'package:slimm_app/src/features/settings/providers/stored_theme.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/sync/providers/sync_session_end.dart';
import 'package:flutter/material.dart' show Brightness;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../features/voice/voice_controller_harness.dart';

const _alice = api.TokenPair(
  userId: 'alice',
  accessToken: 'a',
  refreshToken: 'a',
  accessExpiresAt: 0,
);
const _bob = api.TokenPair(
  userId: 'bob',
  accessToken: 'b',
  refreshToken: 'b',
  accessExpiresAt: 0,
);

final _refProvider = Provider<Ref>((ref) => ref);

Future<ProviderContainer> _container(api.TokenPair tokens) async {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      storeProvider.overrideWith((ref) async => throw StateError('n/a')),
      voiceControllerProvider.overrideWith(
        (ref) => VoiceController(ref, session: FakeSession()),
      ),
    ],
  );
  addTearDown(container.dispose);
  container.read(sessionProvider).set(tokens);
  await pumpEventQueue();
  return container;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the channel providers an account fills start empty again', () async {
    final container = await _container(_alice);
    container.read(dockedThreadsProvider.notifier).state = {null: 'thread-a'};
    container.read(removedRoomsProvider.notifier).state = {'room-a'};
    container
        .read(slowModeLastSentProvider.notifier)
        .recordSent('channel-a', DateTime(2026));
    container.read(categoriesNestProvider.notifier).state = true;

    await clearSessionState(container.read(_refProvider));

    expect(container.read(dockedThreadsProvider), isEmpty);
    expect(container.read(removedRoomsProvider), isEmpty);
    expect(container.read(slowModeLastSentProvider), isEmpty);
    expect(container.read(categoriesNestProvider), isFalse);
  });

  test('the Space default theme is dropped with the session', () async {
    final container = await _container(_alice);
    final theme = ThemeDocument.of(
      AppTokens.forest,
      name: 'Old space',
      author: 'Ren',
      base: 'forest',
      brightness: Brightness.dark,
    );
    await container.read(spaceDefaultThemeProvider.notifier).set(theme);
    expect(container.read(spaceDefaultThemeProvider), isNotNull);

    await clearSessionState(container.read(_refProvider));
    await pumpEventQueue();

    expect(container.read(spaceDefaultThemeProvider), isNull);
    final prefs = await container.read(preferencesProvider.future);
    expect(prefs.getString(spaceDefaultThemeKey), isNull);
  });

  test(
    'a remembered conversation search is not recalled by the next account',
    () async {
      final container = await _container(_alice);
      final session = container.read(sessionProvider);
      const scope = SearchFilter(SearchKey.inChannel, 'dm', channelId: 'dm-1');
      container.read(conversationSearchMemoryProvider).remember(
        scope,
        'secret',
        const [scope],
      );
      expect(
        container.read(conversationSearchMemoryProvider).recall('dm-1'),
        isNotNull,
      );

      session.set(null);
      session.set(_bob);
      await pumpEventQueue();

      expect(
        container.read(conversationSearchMemoryProvider).recall('dm-1'),
        isNull,
      );
    },
  );

  test('recent emoji and activity switches belong to one account', () async {
    final container = await _container(_alice);
    final session = container.read(sessionProvider);
    container.listen(recentEmojiProvider, (_, _) {});
    container.listen(shareListeningProvider, (_, _) {});
    await container.read(recentEmojiProvider.notifier).use('grin');
    await container.read(shareListeningProvider.notifier).setEnabled(true);
    expect(container.read(recentEmojiProvider), ['grin']);

    session.set(_bob);
    await pumpEventQueue();

    expect(container.read(recentEmojiProvider), isEmpty);
    expect(container.read(shareListeningProvider), isFalse);
    final prefs = await container.read(preferencesProvider.future);
    expect(prefs.getBool(shareListeningKey), isNull);
    expect(prefs.getStringList(recentEmojiStorageKey('bob')), isNull);

    session.set(_alice);
    await pumpEventQueue();
    expect(container.read(recentEmojiProvider), ['grin']);
    expect(container.read(shareListeningProvider), isTrue);
  });

  test(
    'a pick made before the shelf loads is not lost to the stored list',
    () async {
      SharedPreferences.setMockInitialValues({
        recentEmojiStorageKey('alice'): ['old'],
      });
      final container = await _container(_alice);
      container.listen(recentEmojiProvider, (_, _) {});
      await container.read(recentEmojiProvider.notifier).use('new');
      await pumpEventQueue();

      expect(container.read(recentEmojiProvider), ['new', 'old']);
    },
  );
}
