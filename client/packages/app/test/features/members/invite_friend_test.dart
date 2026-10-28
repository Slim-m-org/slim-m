// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Invite a friend": offered to a member only while the Space allows it, two
/// taps from the Space menu and one from the member list, and it mints a
/// single-use invite that lasts a day.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/widgets/invite_friend.dart';
import 'package:slimm_app/src/features/members/widgets/member_pane.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/space_menu_button.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

class _FakeSharer implements InviteSharer {
  _FakeSharer({required this.canShare});

  @override
  final bool canShare;
  final shared = <String>[];

  @override
  Future<void> share(String link) async => shared.add(link);
}

class _World {
  _World({required int permissions, required bool membersCanInvite}) {
    container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        storeProvider.overrideWith((ref) async {
          final db = SlimmDatabase(NativeDatabase.memory());
          ref.onDispose(db.close);
          return MessageStore(db);
        }),
        inviteSharerProvider.overrideWithValue(sharer),
        mockApiOverride((request) async {
          switch (request.url.path) {
            case '/me':
              return _json({
                'id': 'self',
                'username': 'self',
                'display_name': 'Self',
                'created_at': 0,
                'permissions': permissions,
              });
            case '/version':
              return _json({
                'name': 'slim-m',
                'version': '1.0.0',
                'protocol': 1,
                'members_can_invite': membersCanInvite,
              });
            case '/invites':
              created.add(jsonDecode(request.body) as Map<String, dynamic>);
              return _json({
                'code': 'abc123',
                'max_uses': 1,
                'uses': 0,
                'expires_at': 0,
                'created_at': 0,
                'revoked': false,
                'usable': true,
              });
            case '/notification-preferences/channels':
            case '/presence':
              return http.Response('[]', 200);
          }
          return http.Response('[]', 200);
        }),
      ],
    );
  }

  final sharer = _FakeSharer(canShare: true);
  final created = <Map<String, dynamic>>[];
  late final ProviderContainer container;

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(body: child),
        ),
      ),
    );
    container.read(meProvider);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
  }
}

http.Response _json(Map<String, dynamic> body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

Widget get _menu =>
    const Align(alignment: Alignment.topRight, child: SpaceMenuButton());

void main() {
  testWidgets('a member reaches the share sheet in two taps from the Space '
      'menu with a single-use day-long invite', (tester) async {
    final world = _World(permissions: 0, membersCanInvite: true);
    addTearDown(world.container.dispose);
    await world.pump(tester, _menu);

    await tester.tap(find.bySemanticsLabel('Space menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Invite a friend'));
    await tester.pumpAndSettle();

    expect(world.created, hasLength(1));
    expect(world.created.single['max_uses'], 1);
    expect(world.created.single['reuse'], true);
    expect(
      world.created.single.containsKey('expires_at'),
      isFalse,
      reason: 'the server stamps a member invite with its own day',
    );
    expect(world.sharer.shared.single, endsWith('/invite/abc123'));
  });

  testWidgets('without the permission or the Space setting there is no '
      'Invite a friend', (tester) async {
    final world = _World(permissions: 0, membersCanInvite: false);
    addTearDown(world.container.dispose);
    await world.pump(tester, _menu);

    await tester.tap(find.bySemanticsLabel('Space menu'));
    await tester.pumpAndSettle();

    expect(find.text('Invite a friend'), findsNothing);
  });

  testWidgets('CREATE_INVITE alone is enough, setting off', (tester) async {
    final world = _World(
      permissions: Perm.createInvite,
      membersCanInvite: false,
    );
    addTearDown(world.container.dispose);
    await world.pump(tester, _menu);

    await tester.tap(find.bySemanticsLabel('Space menu'));
    await tester.pumpAndSettle();

    expect(find.text('Invite a friend'), findsOneWidget);

    await tester.tap(find.text('Invite a friend'));
    await tester.pumpAndSettle();
    final lifetime =
        (world.created.single['expires_at'] as int) -
        DateTime.now().millisecondsSinceEpoch;
    expect(lifetime, closeTo(const Duration(hours: 24).inMilliseconds, 60000));
  });

  testWidgets('a member who may only invite can open their invites from the '
      'Space menu', (tester) async {
    final world = _World(permissions: 0, membersCanInvite: true);
    addTearDown(world.container.dispose);
    await world.pump(tester, _menu);

    await tester.tap(find.bySemanticsLabel('Space menu'));
    await tester.pumpAndSettle();

    expect(find.text('My invites'), findsOneWidget);
  });

  testWidgets('someone with Space settings finds invites there, not twice in '
      'the menu', (tester) async {
    final world = _World(
      permissions: Perm.createInvite,
      membersCanInvite: false,
    );
    addTearDown(world.container.dispose);
    await world.pump(tester, _menu);

    await tester.tap(find.bySemanticsLabel('Space menu'));
    await tester.pumpAndSettle();

    expect(find.text('My invites'), findsNothing);
  });

  testWidgets('the member list header invites in one tap', (tester) async {
    final world = _World(permissions: 0, membersCanInvite: true);
    addTearDown(world.container.dispose);
    await world.pump(tester, const AppMemberPane(channelId: null));

    await tester.tap(find.bySemanticsLabel('Invite a friend'));
    await tester.pumpAndSettle();

    expect(world.created, hasLength(1));
    expect(world.sharer.shared, hasLength(1));
    await tester.pumpWidget(const SizedBox());
    world.container.dispose();
    await tester.pump(const Duration(seconds: 5));
  });
}
