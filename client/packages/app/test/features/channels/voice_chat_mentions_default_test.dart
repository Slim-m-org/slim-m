// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A voice channel's chat defaults to mentions only (decision 0049): a plain message lights nothing, a mention still does.
/// A member's own choice for the channel and a stricter channel default both still win.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/accounts/providers/account_unread.dart';
import 'package:slimm_app/src/features/channels/providers/channel_notification_overrides_controller.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_channel_rows.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_settings_default_notification_section.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

import '../../support/async_wait.dart';
import '../voice/voice_controller_harness.dart';

const _tokens = api.TokenPair(
  userId: 'u-me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 4102444800000,
);

const _everything = api.NotificationPreference.everything;
const _mentions = api.NotificationPreference.mentions;
const _nothing = api.NotificationPreference.nothing;

Channel _channel({
  String kind = 'voice',
  String? level,
  int cursor = 3,
  int mentioned = 0,
}) => Channel(
  id: 'ch-1',
  name: 'hangout',
  kind: kind,
  createdAt: 0,
  position: 0,
  cursor: cursor,
  lastReadSeq: 0,
  mentionedSeq: mentioned,
  slowModeSeconds: 0,
  joinMuted: false,
  defaultNotification: level,
  isPersonalSpace: false,
);

ProviderContainer _container() {
  final apiClient = testApi(
    (_) async => http.Response('[]', 200),
    session: api.SessionStore(tokens: _tokens),
  );
  addTearDown(apiClient.close);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      apiProvider.overrideWithValue(apiClient),
      storeProvider.overrideWith((ref) async {
        final db = SlimmDatabase(NativeDatabase.memory());
        ref.onDispose(db.close);
        return MessageStore(db);
      }),
      voiceRosterProvider('ch-1').overrideWith((ref) => const Stream.empty()),
      voiceControllerProvider.overrideWith(
        (ref) => FixedVoiceController(ref, const VoiceState()),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pumpRow(
  WidgetTester tester,
  ProviderContainer container,
  Channel channel,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: VoiceChannelRow(channel: channel, selected: false),
        ),
      ),
    ),
  );
  await pumpFrames(tester);
}

Finder _row(String state) => find.bySemanticsLabel(RegExp('^hangout$state'));

void main() {
  group('the rule', () {
    const none = ChannelNotificationOverridesState();

    test('a voice channel with no default of its own reads as mentions', () {
      expect(none.effectiveFor(_channel()), _mentions);
      expect(none.effectiveFor(_channel(level: 'everything')), _mentions);
      expect(none.effectiveFor(_channel(kind: 'text')), isNull);
    });

    test('a stricter default and an own choice both still win', () {
      expect(none.effectiveFor(_channel(level: 'nothing')), _nothing);
      const own = ChannelNotificationOverridesState(
        byChannel: {'ch-1': _everything},
      );
      expect(own.effectiveFor(_channel()), _everything);
    });

    test('the account badge counts a mention, not a plain message', () {
      expect(countUnread([_channel()], none).channels, 0);
      expect(countUnread([_channel(mentioned: 3)], none).mentions, 1);
      const own = ChannelNotificationOverridesState(
        byChannel: {'ch-1': _everything},
      );
      expect(countUnread([_channel()], own).channels, 1);
    });
  });

  group('the rail row', () {
    testWidgets('a plain message lights nothing, a mention does', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final container = _container();

      await _pumpRow(tester, container, _channel());
      expect(_row(r'$'), findsOne);

      await _pumpRow(tester, container, _channel(mentioned: 3));
      expect(_row(', mentioned'), findsOne);
      semantics.dispose();
    });

    testWidgets('choosing all messages for it lights a plain message', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final container = _container();
      container
          .read(channelNotificationOverridesProvider.notifier)
          .applyRemote('ch-1', _everything);

      await _pumpRow(tester, container, _channel());
      expect(_row(', unread'), findsOne);
      semantics.dispose();
    });
  });

  testWidgets(
    'channel settings shows the voice default and offers no louder one',
    (tester) async {
      final container = _container();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: Scaffold(
              body: ChannelDefaultNotificationSection(channel: _channel()),
            ),
          ),
        ),
      );
      await pumpFrames(tester);
      expect(find.text('Mentions only'), findsOne);

      await tester.tap(find.text('Default notifications'));
      await pumpFrames(tester);
      expect(find.text('Muted'), findsOne);
      expect(find.text('All messages'), findsNothing);
    },
  );
}
