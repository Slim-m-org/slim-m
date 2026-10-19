// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `VoiceCallWithChatPane`/`VoiceCallWithChatTabs` give a voice channel the
/// same transcript and composer a text channel has, by mounting and
/// unmounting a real `ChannelScreen` rather than a parallel implementation.
///
/// This pins the two things that reuse could still get wrong: that toggling
/// the pane or the compact chat view actually mounts and unmounts
/// `ChannelScreen`, so `MountedChannels` registration pairs the way
/// `mounted_channels.dart`'s own doc says the retention sweep depends on,
/// rather than merely hiding it at zero width; and that a member can
/// actually read and send in the surface that mounts.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/composer/widgets/composer_attachments.dart'
    show StagedSend;
import 'package:slimm_app/src/features/channels/providers/mounted_channels.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/features/channels/screens/channel_screen.dart';
import 'package:slimm_app/src/features/voice/screens/voice_text_pane.dart';
import 'package:slimm_app/src/features/composer/widgets/composer.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import 'support/fake_sync.dart';
import 'support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'bob',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, dynamic> _meJson() => {
  'id': 'bob',
  'username': 'bob',
  'display_name': 'Bob',
  'created_at': 0,
  'permissions': 0,
};

http.Response _emptyJsonList() => http.Response(
  jsonEncode([]),
  200,
  headers: {'content-type': 'application/json'},
);

class _Harness {
  _Harness({required this.container, required this.posted});

  final ProviderContainer container;

  /// Every message body `POST /channels/v1/messages` actually received.
  final List<String> posted;
}

/// Mounts [child] over a real local store seeded with one voice channel
/// ('v1'), the same shape `channel_screen_test.dart` uses for a text one -
/// nothing about sending or read-marking is specific to a channel's kind.
Future<_Harness> _mount(WidgetTester tester, Widget child) async {
  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final store = MessageStore(db);
  await store.upsertChannels([
    const api.Channel(
      id: 'v1',
      name: 'general voice',
      kind: 'voice',
      createdAt: 0,
    ),
  ]);

  final posted = <String>[];
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      storeProvider.overrideWith((ref) async => store),
      syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
      mockApiOverride((request) async {
        if (request.method == 'POST' &&
            request.url.path == '/channels/v1/messages') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          posted.add(body['content'] as String);
          return http.Response(
            jsonEncode({
              'id': body['id'],
              'channel_id': 'v1',
              'author_id': 'bob',
              'author_display_name': 'Bob',
              'seq': 1,
              'content': body['content'],
              'created_at': 1000,
              'edited_at': null,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'GET' && request.url.path == '/me') {
          return http.Response(
            jsonEncode(_meJson()),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'PUT' &&
            request.url.path == '/channels/v1/read') {
          return http.Response(
            jsonEncode({'last_read_seq': 0, 'unread': 0}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return _emptyJsonList();
      }),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: child),
      ),
    ),
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  return _Harness(container: container, posted: posted);
}

/// See `channel_screen_mounted_channels_test.dart` for why this, rather than
/// flutter_test's own teardown, is what unmounts `ChannelScreen`: drift
/// defers its query-stream cleanup by one event loop turn, which the "no
/// pending timers" check runs before if left to the framework alone.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

/// The compact call body under a stand-in for the app bar's chat action,
/// which is what drives it on a phone.
Widget _tabsWithAppBarAction() => const Column(
  children: [
    VoiceChatAction(),
    Expanded(
      child: VoiceCallWithChatTabs(channelId: 'v1', call: Text('CALL')),
    ),
  ],
);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  group('VoiceCallWithChatPane', () {
    testWidgets(
      'closed by default: the call fills the space and nothing registers',
      (tester) async {
        final harness = await _mount(
          tester,
          const VoiceCallWithChatPane(channelId: 'v1', call: Text('CALL')),
        );

        expect(find.text('CALL'), findsOneWidget);
        expect(find.byType(ChannelScreen), findsNothing);
        expect(
          harness.container.read(mountedChannelsProvider).openChannelIds,
          isEmpty,
        );

        await _unmount(tester);
      },
    );

    testWidgets(
      'opening the pane mounts the transcript and composer beside the call, '
      'and a member can send',
      (tester) async {
        final harness = await _mount(
          tester,
          const VoiceCallWithChatPane(channelId: 'v1', call: Text('CALL')),
        );

        harness.container.read(voiceChatPaneVisibleProvider.notifier).state =
            true;
        await _settle(tester);

        expect(
          find.text('CALL'),
          findsOneWidget,
          reason: 'the call must stay up beside the docked pane',
        );
        expect(find.byType(ChannelScreen), findsOneWidget);
        expect(find.byType(Composer), findsOneWidget);
        expect(harness.container.read(mountedChannelsProvider).openChannelIds, {
          'v1',
        });

        await tester.enterText(
          find.descendant(
            of: find.byType(Composer),
            matching: find.byType(TextField),
          ),
          'hello from voice chat',
        );
        final composer = tester.widget<Composer>(find.byType(Composer));
        await composer.onSend(const StagedSend([]));
        await _settle(tester);

        expect(harness.posted, contains('hello from voice chat'));

        await _unmount(tester);
      },
    );

    testWidgets(
      'closing the pane unmounts the transcript and unregisters the channel',
      (tester) async {
        final harness = await _mount(
          tester,
          const VoiceCallWithChatPane(channelId: 'v1', call: Text('CALL')),
        );
        final notifier = harness.container.read(
          voiceChatPaneVisibleProvider.notifier,
        );

        notifier.state = true;
        await _settle(tester);
        expect(harness.container.read(mountedChannelsProvider).openChannelIds, {
          'v1',
        });

        notifier.state = false;
        await _settle(tester);

        expect(
          find.byType(ChannelScreen),
          findsNothing,
          reason:
              'a closed pane must unmount ChannelScreen, not merely hide '
              'it at zero width',
        );
        expect(
          harness.container.read(mountedChannelsProvider).openChannelIds,
          isEmpty,
          reason:
              'closing the pane must give the registration back up, or the '
              'retention sweep pins this channel\'s history forever',
        );

        await _unmount(tester);
      },
    );
  });

  group('VoiceCallWithChatTabs', () {
    testWidgets(
      'shows the call full-screen with the chat action beside it, nothing registered',
      (tester) async {
        final harness = await _mount(tester, _tabsWithAppBarAction());

        expect(find.text('CALL'), findsOneWidget);
        expect(find.byIcon(AppIcons.chat), findsOneWidget);
        expect(find.byIcon(AppIcons.hash), findsNothing);
        expect(find.byType(ChannelScreen), findsNothing);
        expect(
          harness.container.read(mountedChannelsProvider).openChannelIds,
          isEmpty,
        );

        await _unmount(tester);
      },
    );

    testWidgets(
      'opening chat swaps the call out entirely, registers the channel, and '
      'a member can send; going back restores the call and unregisters it',
      (tester) async {
        final harness = await _mount(tester, _tabsWithAppBarAction());

        await tester.tap(find.byIcon(AppIcons.chat));
        await _settle(tester);

        expect(
          find.text('CALL'),
          findsNothing,
          reason:
              'the call must not stay mounted behind the chat view at '
              'compact width',
        );
        expect(find.byType(ChannelScreen), findsOneWidget);
        expect(find.byType(Composer), findsOneWidget);
        expect(harness.container.read(mountedChannelsProvider).openChannelIds, {
          'v1',
        });

        await tester.enterText(
          find.descendant(
            of: find.byType(Composer),
            matching: find.byType(TextField),
          ),
          'hello from the compact chat view',
        );
        final composer = tester.widget<Composer>(find.byType(Composer));
        await composer.onSend(const StagedSend([]));
        await _settle(tester);
        expect(harness.posted, contains('hello from the compact chat view'));

        await tester.tap(find.byIcon(AppIcons.chat));
        await _settle(tester);

        expect(find.text('CALL'), findsOneWidget);
        expect(find.byType(ChannelScreen), findsNothing);
        expect(
          harness.container.read(mountedChannelsProvider).openChannelIds,
          isEmpty,
          reason: 'going back to the call must unregister the channel again',
        );

        await _unmount(tester);
      },
    );
  });
}
