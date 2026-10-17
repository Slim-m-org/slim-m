// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The member pane's role sections, keyed on the hoisted role each member
/// profile carries: only hoisted roles get a heading, ordered by position,
/// with everyone else under Online.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/members/widgets/member_pane.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

UserProfile _member(
  String id,
  String name, {
  List<(String, String)> roles = const [],
  (String, int)? hoisted,
}) => UserProfile(
  id: id,
  username: id,
  displayName: name,
  createdAt: 0,
  roleIds: [for (final r in roles) r.$1],
  roles: [for (final r in roles) r.$2],
  hoistedRoleId: hoisted?.$1,
  hoistedRolePosition: hoisted?.$2,
);

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

SlimmApi _fakeApi(SessionStore session, List<String> memberIds) => SlimmApi(
  baseUrl: Uri.parse('http://localhost:8080'),
  session: session,
  httpClient: MockClient((request) async {
    if (request.url.path == '/me') {
      return http.Response(
        jsonEncode({
          'id': 'self',
          'username': 'self',
          'display_name': 'Self',
          'created_at': 0,
          'permissions': 0,
        }),
        200,
      );
    }
    if (request.url.path == '/presence') {
      return http.Response(
        jsonEncode([
          for (final id in memberIds) {'user_id': id, 'status': 'online'},
        ]),
        200,
      );
    }
    throw StateError('unexpected request in this test: ${request.url}');
  }),
);

Future<void> _pump(WidgetTester tester, List<UserProfile> members) async {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      apiProvider.overrideWith((ref) {
        final api = _fakeApi(ref.watch(sessionProvider), [
          for (final m in members) m.id,
        ]);
        ref.onDispose(api.close);
        return api;
      }),
      membersProvider.overrideWith((ref) async => members),
      channelMembersProvider.overrideWith((ref, _) async => members),
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
  await tester.pumpAndSettle();
}

double _top(WidgetTester tester, Finder finder) => tester.getTopLeft(finder).dy;

void main() {
  const admin = ('r-admin', 'Admin');
  const mod = ('r-mod', 'Mod');
  const guest = ('r-guest', 'Guest');

  testWidgets('only hoisted roles get a heading, highest position first', (
    tester,
  ) async {
    await _pump(tester, [
      _member('1', 'Vera', roles: [guest]),
      _member('2', 'Max', roles: [mod], hoisted: ('r-mod', 5)),
      _member('3', 'Ada', roles: [admin, guest], hoisted: ('r-admin', 9)),
      _member('4', 'Zoe', roles: [guest, mod], hoisted: ('r-mod', 5)),
    ]);

    expect(find.textContaining('GUEST ·'), findsNothing);
    final adminHeading = find.textContaining('ADMIN · 1');
    final modHeading = find.textContaining('MOD · 2');
    final onlineHeading = find.textContaining('ONLINE · 1');
    expect(adminHeading, findsOneWidget);
    expect(modHeading, findsOneWidget);
    expect(onlineHeading, findsOneWidget);

    final ada = _top(tester, find.text('Ada'));
    final max = _top(tester, find.text('Max'));
    final zoe = _top(tester, find.text('Zoe'));
    final vera = _top(tester, find.text('Vera'));
    expect(_top(tester, adminHeading), lessThan(ada));
    expect(ada, lessThan(_top(tester, modHeading)));
    expect(_top(tester, modHeading), lessThan(max));
    expect(max, lessThan(zoe));
    expect(zoe, lessThan(_top(tester, onlineHeading)));
    expect(_top(tester, onlineHeading), lessThan(vera));
  });

  testWidgets('with no hoisted role there are no role headings', (
    tester,
  ) async {
    await _pump(tester, [
      _member('1', 'Vera', roles: [guest]),
      _member('2', 'Max', roles: [mod, guest]),
    ]);

    expect(find.textContaining('ONLINE · 2'), findsOneWidget);
    expect(find.textContaining('MOD ·'), findsNothing);
    expect(find.textContaining('GUEST ·'), findsNothing);
  });
}
