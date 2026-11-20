// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A permissions grid with unsaved cell edits asks before a back gesture, or
/// Back to channels on the routed screen and in a pane, drops them.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_permissions.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/settings/providers/channel_permissions_selection.dart';
import 'package:slimm_app/src/features/settings/screens/admin/channel_permissions_screen.dart';
import 'package:slimm_app/src/features/settings/widgets/admin/channel_permissions_grid.dart';
import 'package:slimm_app/src/features/settings/widgets/admin/channel_permissions_heading.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_sub_pages.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart' show Channel, MessageStore;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';

const _everyone = api.Role(
  id: 'role-everyone',
  name: '@everyone',
  permissions: 0,
  isEveryone: true,
  createdAt: 0,
);

const _channel = Channel(
  id: 'c-general',
  name: 'general',
  kind: 'text',
  createdAt: 0,
  position: 0,
  topic: '',
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
);

Future<void> _openGrid(
  WidgetTester tester, {
  Widget page = const Scaffold(body: ChannelPermissionsGrid(channel: _channel)),
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final client = MockClient(
    (_) async => http.Response(
      jsonEncode({'overwrites': <Object>[]}),
      200,
      headers: {'content-type': 'application/json'},
    ),
  );
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(
        api.SessionStore(
          tokens: const api.TokenPair(
            userId: 'self',
            accessToken: 'access',
            refreshToken: 'refresh',
            accessExpiresAt: 0,
          ),
        ),
      ),
      rolesProvider.overrideWith((ref) async => [_everyone]),
      membersProvider.overrideWith((ref) async => <api.UserProfile>[]),
      storeProvider.overrideWith((ref) => Completer<MessageStore>().future),
      myChannelPermissionsProvider(
        _channel.id,
      ).overrideWith((ref) => Perm.sendMessages),
      apiProvider.overrideWith(
        (ref) => api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: client,
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute<void>(builder: (_) => page)),
            child: const Text('open grid'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open grid'));
  await pumpFrames(tester);
}

final _cell = find.byKey(
  const ValueKey('cell:role:role-everyone:${Perm.sendMessages}'),
);
final _backToChannels = find.byTooltip('Back to channels');

/// The routed screen opened on its list, then on [_channel] as a pick would.
Future<void> _openRoutedOnChannel(WidgetTester tester) async {
  await _openGrid(tester, page: const ChannelPermissionsScreen());
  ProviderScope.containerOf(
    tester.element(find.text('Channel permissions').first),
  ).read(channelPermissionsSelectionProvider.notifier).state = _channel;
  await pumpFrames(tester);
}

/// The Space settings pane: its heading beside the grid, both in one stack.
Future<void> _openPaneOnChannel(WidgetTester tester) async {
  final stack = SettingsSubPageStack();
  addTearDown(stack.dispose);
  await _openGrid(
    tester,
    page: ProviderScope(
      overrides: [
        channelPermissionsSelectionProvider.overrideWith((ref) => _channel),
      ],
      child: Scaffold(
        body: SettingsSubPages(
          stack: stack,
          child: const Column(
            children: [
              ChannelPermissionsHeading(),
              Expanded(child: ChannelPermissionsPane()),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<void> _tapThenSettle(WidgetTester tester, Finder target) async {
  await tester.tap(target);
  await pumpFrames(tester);
}

void main() {
  for (final (where, open) in [
    ('on the routed screen', _openRoutedOnChannel),
    ('in a settings pane', _openPaneOnChannel),
  ]) {
    testWidgets('Back to channels $where asks first with unsaved edits', (
      tester,
    ) async {
      await open(tester);
      await _tapThenSettle(tester, _cell);

      await _tapThenSettle(tester, _backToChannels);
      expect(find.text('Discard your changes?'), findsOneWidget);
      await _tapThenSettle(tester, find.text('Keep editing'));
      expect(find.text('Save changes'), findsOneWidget);
      expect(_cell, findsOneWidget);

      await _tapThenSettle(tester, _backToChannels);
      await _tapThenSettle(tester, find.text('Discard').last);
      expect(_cell, findsNothing);
      expect(_backToChannels, findsNothing);
    });

    testWidgets('Back to channels $where with nothing edited goes straight', (
      tester,
    ) async {
      await open(tester);
      expect(_cell, findsOneWidget);

      await _tapThenSettle(tester, _backToChannels);

      expect(find.text('Discard your changes?'), findsNothing);
      expect(_cell, findsNothing);
    });
  }

  testWidgets('back with unsaved cell edits asks, and Keep editing stays', (
    tester,
  ) async {
    await _openGrid(tester);
    await tester.tap(
      find.byKey(
        const ValueKey('cell:role:role-everyone:${Perm.sendMessages}'),
      ),
    );
    await pumpFrames(tester);

    await tester.binding.handlePopRoute();
    await pumpFrames(tester);
    expect(find.text('Discard your changes?'), findsOneWidget);

    await tester.tap(find.text('Keep editing'));
    await pumpFrames(tester);
    expect(find.text('Save changes'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await pumpFrames(tester);
    await tester.tap(find.text('Discard').last);
    await pumpFrames(tester);
    expect(find.text('open grid'), findsOneWidget);
  });

  testWidgets('back with nothing edited leaves without asking', (tester) async {
    await _openGrid(tester);

    await tester.binding.handlePopRoute();
    await pumpFrames(tester);

    expect(find.text('Discard your changes?'), findsNothing);
    expect(find.text('open grid'), findsOneWidget);
  });
}
