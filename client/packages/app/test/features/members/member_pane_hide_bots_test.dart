// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A Space can leave bots out of the member list: the Bots section and its
/// rows go, the header counts people only, and a settings change reaches a
/// pane that is already open.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/members/providers/roster_grouping.dart';
import 'package:slimm_app/src/features/members/widgets/member_pane.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart' show MessageStore, SlimmDatabase;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

import '../../support/async_wait.dart';

UserProfile _profile(String id, String name, {bool isBot = false}) =>
    UserProfile(
      id: id,
      username: id,
      displayName: name,
      createdAt: 0,
      isBot: isBot,
    );

final _roster = [
  _profile('1', 'Priya'),
  _profile('2', 'Kess'),
  _profile('3', 'Botty', isBot: true),
];

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

class _Space {
  bool hideBots;

  _Space({required this.hideBots});

  Future<http.Response> answer(http.Request request) async {
    return switch (request.url.path) {
      '/me' => http.Response(
        jsonEncode({
          'id': 'self',
          'username': 'self',
          'display_name': 'Self',
          'created_at': 0,
          'permissions': 0,
        }),
        200,
      ),
      '/version' => http.Response(
        jsonEncode({
          'name': 'slim-m',
          'version': '1.0.0',
          'protocol': 1,
          'hide_bots_in_member_list': hideBots,
        }),
        200,
      ),
      _ => http.Response('[]', 200),
    };
  }
}

/// The session is empty so the sync controller never opens a socket; the api
/// still carries tokens, and the controller applies events the way the socket would.
Future<ProviderContainer> _pumpPane(WidgetTester tester, _Space space) async {
  final store = MessageStore(SlimmDatabase(NativeDatabase.memory()));
  addTearDown(store.db.close);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore()),
      storeProvider.overrideWith((ref) async => store),
      apiProvider.overrideWith((ref) {
        final api = testApi(
          space.answer,
          session: SessionStore(tokens: _tokens),
        );
        ref.onDispose(api.close);
        return api;
      }),
      membersProvider.overrideWith((ref) async => _roster),
      channelMembersProvider.overrideWith((ref, _) async => _roster),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: AppMemberPane(channelId: 'c1')),
      ),
    ),
  );
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
  return container;
}

void main() {
  testWidgets('bots are listed in their own section while the Space shows '
      'them', (tester) async {
    await _pumpPane(tester, _Space(hideBots: false));

    expect(find.textContaining('BOTS · 1'), findsOneWidget);
    expect(find.text('Botty'), findsOneWidget);
    expect(find.textContaining('MEMBERS · 3'), findsOneWidget);
  });

  testWidgets('a Space that hides bots lists people only and counts them', (
    tester,
  ) async {
    await _pumpPane(tester, _Space(hideBots: true));

    expect(find.textContaining('BOTS'), findsNothing);
    expect(find.text('Botty'), findsNothing);
    expect(find.text('Priya'), findsOneWidget);
    expect(find.text('Kess'), findsOneWidget);
    expect(find.textContaining('MEMBERS · 2'), findsOneWidget);
  });

  testWidgets('turning it on with the pane open drops the section without a '
      'reload, and turning it off brings it back', (tester) async {
    final space = _Space(hideBots: false);
    final container = await _pumpPane(tester, space);
    final sync = container.read(syncControllerProvider.notifier);
    expect(find.text('Botty'), findsOneWidget);

    Future<void> adminChanges({required bool hideBots}) async {
      space.hideBots = hideBots;
      await tester.runAsync(
        () => sync.applyServerEventForTest(const SpaceSettingsChanged()),
      );
      await waitUntil(
        tester,
        () => container.read(hideBotsInMemberListProvider) == hideBots,
        reason: 'the pane never heard about the new setting',
      );
    }

    await adminChanges(hideBots: true);
    expect(find.textContaining('BOTS'), findsNothing);
    expect(find.text('Botty'), findsNothing);
    expect(find.textContaining('MEMBERS · 2'), findsOneWidget);

    await adminChanges(hideBots: false);
    expect(find.textContaining('BOTS · 1'), findsOneWidget);
    expect(find.text('Botty'), findsOneWidget);
  });
}
