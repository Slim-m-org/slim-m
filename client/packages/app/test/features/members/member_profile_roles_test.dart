// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The card's Roles section, Discord's way: pills in the member's own role
/// order with each role's colour as a dot, nothing at all for a member with
/// no roles, and for a role manager a "+" that opens the toggles in place
/// and a cross on each pill they may take away.
library;

import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/members/widgets/member_profile_roles.dart';
import 'package:slimm_app/src/features/members/widgets/role_color.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/fake_api.dart';

api.Role _role(String id, String name, {int permissions = 0}) => api.Role(
  id: id,
  name: name,
  permissions: permissions,
  isEveryone: false,
  createdAt: 0,
);

final _roles = [
  _role('r-admin', 'Admins', permissions: Perm.administrator),
  _role('r-mods', 'Moderators'),
  _role('r-regs', 'Regulars'),
  _role('r-help', 'Helpers'),
  const api.Role(
    id: 'r-everyone',
    name: 'everyone',
    permissions: 0,
    isEveryone: true,
    createdAt: 0,
  ),
];

api.UserProfile _maya({List<String> held = const ['r-admin', 'r-mods']}) {
  final names = {for (final r in _roles) r.id: r.name};
  const colours = {'r-admin': 0, 'r-mods': null, 'r-regs': 4};
  return api.UserProfile(
    id: 'user-maya',
    username: 'maya',
    displayName: 'maya',
    createdAt: 0,
    roleIds: held,
    roles: [for (final id in held) names[id]!],
    roleColors: [for (final id in held) colours[id]],
  );
}

Future<List<String>> _pump(
  WidgetTester tester,
  api.UserProfile profile, {
  bool manager = false,
  bool touch = false,
  int status = 204,
  bool rolesFail = false,
}) async {
  final calls = <String>[];
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
      myPermissionsProvider.overrideWithValue(
        manager ? Perm.manageRoles : Perm.sendMessages,
      ),
      membersProvider.overrideWith((ref) async => [profile]),
      rolesProvider.overrideWith(
        (ref) async =>
            rolesFail ? throw StateError('roles unavailable') : _roles,
      ),
      mockApiOverride((request) async {
        calls.add('${request.method} ${request.url.path}');
        return status == 204
            ? http.Response('', 204)
            : http.Response(
                jsonEncode({'error': 'you cannot do that'}),
                status,
                headers: const {'content-type': 'application/json'},
              );
      }),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: AppTouchTargets(
            enabled: touch,
            child: SingleChildScrollView(
              child: SizedBox(
                width: 300,
                child: MemberProfileRoles(
                  profile: profile,
                  canManageRoles: manager,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return calls;
}

Finder _add() => find.bySemanticsLabel('Roles for maya');

Finder _remove(String role) => find.bySemanticsLabel('Remove $role from maya');

Finder _dotOf(Color colour) => find.byWidgetPredicate(
  (w) =>
      w is DecoratedBox &&
      w.decoration is BoxDecoration &&
      (w.decoration as BoxDecoration).shape == BoxShape.circle &&
      (w.decoration as BoxDecoration).color == colour,
);

void main() {
  testWidgets('no roles and no right to grant one is no section at all', (
    tester,
  ) async {
    await _pump(tester, _maya(held: const []));
    expect(find.text('ROLES'), findsNothing);
    expect(_add(), findsNothing);
  });

  testWidgets('pills keep the role order, own case, colour or neutral dot', (
    tester,
  ) async {
    await _pump(tester, _maya(held: const ['r-admin', 'r-mods', 'r-regs']));

    expect(find.text('ROLES'), findsOneWidget);
    // Reading order: the pills wrap, so a later one may start a new line.
    final at = [
      for (final name in ['Admins', 'Moderators', 'Regulars'])
        tester.getTopLeft(find.text(name)),
    ];
    for (var i = 1; i < at.length; i++) {
      final before = at[i - 1];
      expect(
        at[i].dy > before.dy || (at[i].dy == before.dy && at[i].dx > before.dx),
        isTrue,
        reason: 'pill $i follows pill ${i - 1}',
      );
    }
    expect(find.text('ADMINS'), findsNothing);
    expect(_dotOf(rolePalette[0].color), findsOneWidget);
    expect(_dotOf(rolePalette[4].color), findsOneWidget);
    expect(_dotOf(AppTokens.light.borderStrong), findsOneWidget);
    expect(_add(), findsNothing, reason: 'a plain member edits nothing');
    expect(_remove('Moderators'), findsNothing);
  });

  testWidgets('a manager sees the heading and a + even with no roles', (
    tester,
  ) async {
    await _pump(tester, _maya(held: const []), manager: true);
    expect(find.text('ROLES'), findsOneWidget);
    expect(_add(), findsOneWidget);
  });

  testWidgets('+ opens the toggles in place, and a toggle grants the role', (
    tester,
  ) async {
    final calls = await _pump(tester, _maya(), manager: true);
    expect(find.text('Helpers'), findsNothing);

    await tester.tap(_add());
    await tester.pump();
    expect(find.text('Helpers'), findsOneWidget);
    expect(find.text('everyone'), findsNothing, reason: 'nothing to change');

    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is AppToggle && w.semanticLabel == 'Helpers for maya',
      ),
    );
    await tester.pump();
    expect(calls, contains('PUT /members/user-maya/roles/r-help'));
  });

  testWidgets('hovering a pill the manager may take away shows its cross', (
    tester,
  ) async {
    final calls = await _pump(tester, _maya(), manager: true);
    expect(_remove('Admins'), findsNothing, reason: 'beyond their own bits');
    expect(_remove('Moderators'), findsOneWidget);
    expect(find.byIcon(AppIcons.dismiss), findsNothing);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('Moderators')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byIcon(AppIcons.dismiss), findsOneWidget);
    final pill = tester.getRect(find.text('Moderators'));

    await tester.tap(_remove('Moderators'));
    await tester.pump();
    expect(calls, contains('DELETE /members/user-maya/roles/r-mods'));
    expect(
      tester.getRect(find.text('Moderators')),
      pill,
      reason: 'the cross takes the dot place, so the name never moves',
    );
  });

  testWidgets('a refused change says so inline, in the section', (
    tester,
  ) async {
    await _pump(tester, _maya(), manager: true, status: 403);

    await tester.tap(_remove('Moderators'));
    await tester.pump();
    await tester.pump();
    expect(find.byWidgetPredicate((w) => w is AppErrorState), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is SnackBar), findsNothing);
  });

  testWidgets('on touch there is no cross; the + is a full finger target', (
    tester,
  ) async {
    await _pump(tester, _maya(), manager: true, touch: true);
    expect(_remove('Moderators'), findsNothing);
    final add = tester.getSize(_add());
    expect(add.width, greaterThanOrEqualTo(AppSizes.rowTouch));
    expect(add.height, greaterThanOrEqualTo(AppSizes.rowTouch));
  });

  testWidgets('a role list that fails to load says so with a retry', (
    tester,
  ) async {
    await _pump(tester, _maya(), manager: true, rolesFail: true);
    await tester.tap(_add());
    await tester.pump();
    expect(find.text('Could not load the roles.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });
}
