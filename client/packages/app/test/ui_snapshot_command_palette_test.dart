// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The command palette with channels, people and a message hit, at a phone
/// width and a desktop width in dark and light. The overflow assertion runs
/// everywhere; the PNGs are written only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/member_presence.dart';
import 'package:slimm_app/src/providers/presence_view.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/home_shell.dart';
import 'package:slimm_app/src/widgets/command_palette.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import 'ui_snapshot_support.dart';

api.UserProfile _person(
  String id,
  String name, {
  bool bot = false,
  List<String> roles = const [],
}) => api.UserProfile(
  id: id,
  username: name.toLowerCase().replaceAll(' ', ''),
  displayName: name,
  createdAt: 0,
  isBot: bot,
  roles: roles,
);

final _members = [
  _person('p-kiki', 'Kiki', roles: const ['Moderator']),
  _person('p-modlog', 'Mod Log', bot: true),
  _person('p-automod', 'Automod', bot: true),
];

http.Client _client() => MockClient((request) async {
  if (request.url.path == '/search/messages') {
    return http.Response(
      jsonEncode([
        {
          'id': 'm-gap',
          'channel_id': 'c-dev',
          'author_id': 'p-nick',
          'author_display_name': 'Nick',
          'seq': 1,
          'content': 'weird gap log from mod bot',
          'created_at': DateTime(2026, 10, 14).millisecondsSinceEpoch,
          'edited_at': null,
        },
      ]),
      200,
    );
  }
  return fixtureResponse(request);
});

Future<void> _openPalette(WidgetTester tester) async {
  final container = ProviderScope.containerOf(
    tester.element(find.byType(HomeShell)),
  );
  final store = await container.read(storeProvider.future);
  await store.upsertCategory(
    const api.ChannelCategory(
      id: 'cat-mod',
      name: 'Moderation',
      position: 2,
      createdAt: 0,
    ),
  );
  await store.upsertChannels(const [
    api.Channel(
      id: 'c-automod',
      name: 'automod-log',
      kind: 'text',
      createdAt: 0,
      categoryId: 'cat-mod',
    ),
    api.Channel(
      id: 'c-modlog',
      name: 'modlog',
      kind: 'text',
      createdAt: 1,
      categoryId: 'cat-mod',
    ),
    api.Channel(id: 'c-dev', name: 'dev', kind: 'text', createdAt: 2),
  ]);
  await tester.pump(const Duration(milliseconds: 350));
  unawaited(openCommandPalette(tester.element(find.byType(HomeShell))));
  await tester.pump(const Duration(milliseconds: 350));
  await tester.enterText(find.byKey(const Key('command-palette-input')), 'mod');
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  for (final theme in const ['dark', 'light']) {
    for (final viewport in const ['phone-portrait', 'desktop']) {
      testWidgets('command palette at $viewport ($theme) fits its viewport', (
        tester,
      ) async {
        await renderSurface(
          tester,
          '/channels/c-modlog',
          viewport,
          theme,
          'command-palette-$viewport-$theme',
          overrides: [
            membersProvider.overrideWith((ref) async => _members),
            presenceForProvider(
              'p-kiki',
            ).overrideWith((ref) => AppPresence.online),
            apiProvider.overrideWith((ref) {
              final client = api.SlimmApi(
                baseUrl: Uri.parse('http://localhost:8080'),
                session: ref.watch(sessionProvider),
                httpClient: _client(),
              );
              ref.onDispose(client.close);
              return client;
            }),
          ],
          afterSettle: _openPalette,
        );
      });
    }
  }
}
