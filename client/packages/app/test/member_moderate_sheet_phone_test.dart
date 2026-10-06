// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Moderate sheet on a 390x844 phone, driven through the real member
/// card: one scroll view, the destructive action reachable, a compact roles
/// row instead of a tall toggle per role, and the desktop popover untouched.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/action_labels.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/member_presence.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/member_profile.dart';
import 'package:slimm_design_system/design_system.dart';

import 'ui_snapshot_support.dart';

const _maya = api.UserProfile(
  id: 'user-maya',
  username: 'maya',
  displayName: 'maya',
  createdAt: 0,
  roleIds: ['role-r1'],
);

final _roles = <api.Role>[
  const api.Role(
    id: 'role-everyone',
    name: 'everyone',
    permissions: 0,
    isEveryone: true,
    createdAt: 0,
  ),
  for (var i = 1; i <= 11; i++)
    api.Role(
      id: 'role-r$i',
      name: 'role$i',
      permissions: Perm.sendMessages,
      isEveryone: false,
      createdAt: 0,
      managedBotId: i > 4 ? 'bot-$i' : null,
    ),
];

const _manager =
    Perm.kickMembers | Perm.banMembers | Perm.manageRoles | Perm.sendMessages;

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _me = api.Me(
  id: 'self',
  username: 'self',
  displayName: 'Self',
  createdAt: 0,
  permissions: 0,
);

class _Rig {
  final calls = <String>[];
  late final Widget app;
}

_Rig _rig({required Brightness brightness, int permissions = _manager}) {
  final rig = _Rig();
  rig.app = ProviderScope(
    overrides: [
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      apiProvider.overrideWith(
        (ref) => api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            if (request.method != 'GET') {
              rig.calls.add('${request.method} ${request.url.path}');
            }
            return http.Response(jsonEncode(<String, Object?>{}), 200);
          }),
        ),
      ),
      meProvider.overrideWith((ref) async => _me),
      myPermissionsProvider.overrideWithValue(permissions),
      membersProvider.overrideWith((ref) async => [_maya]),
      rolesProvider.overrideWith((ref) async => _roles),
    ],
    child: RepaintBoundary(
      key: snapshotBoundary,
      child: MaterialApp(
        theme: buildTheme(
          brightness,
          brightness == Brightness.dark ? AppTokens.dark : AppTokens.light,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => showMemberProfile(
                  context,
                  profile: _maya,
                  initiallyModerating: true,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  return rig;
}

Future<_Rig> _openSheet(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  Brightness brightness = Brightness.light,
  int permissions = _manager,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final rig = _rig(brightness: brightness, permissions: permissions);
  await tester.pumpWidget(rig.app);
  await tester.pump();
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return rig;
}

void main() {
  const viewport = Size(390, 844);

  testWidgets('the sheet is one scroll view that reaches Remove', (
    tester,
  ) async {
    await _openSheet(tester);
    final scroll = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byType(Scrollable),
    );
    expect(scroll, findsOneWidget, reason: 'one scroll view for the sheet');

    final remove = find.widgetWithText(AppButton, ActionLabels.removeFromSpace);
    await tester.scrollUntilVisible(remove, 200, scrollable: scroll);
    final rect = tester.getRect(remove);
    expect(rect.bottom, lessThanOrEqualTo(viewport.height));
    expect(rect.top, greaterThanOrEqualTo(0));
  });

  testWidgets('Time out and Remove are reachable without scrolling', (
    tester,
  ) async {
    await _openSheet(tester);
    for (final label in ['5m', ActionLabels.removeFromSpace]) {
      final finder = find.text(label);
      expect(finder, findsOneWidget);
      final rect = tester.getRect(finder);
      expect(
        rect.bottom,
        lessThanOrEqualTo(viewport.height),
        reason: '$label must sit inside the first screen of the sheet',
      );
    }
  });

  testWidgets('the roles list does not spend a tall row on every role', (
    tester,
  ) async {
    await _openSheet(tester);
    expect(find.byType(AppToggle), findsNothing);
    expect(find.text('Roles'), findsWidgets);
  });

  testWidgets('opening the roles row lists every role and stays scrollable', (
    tester,
  ) async {
    await _openSheet(tester);
    await tester.tap(find.text('Roles'));
    await tester.pumpAndSettle();
    expect(find.byType(AppToggle), findsNWidgets(_roles.length));

    final scroll = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scroll).position;
    expect(position.maxScrollExtent, greaterThan(0));
    final remove = find.widgetWithText(AppButton, ActionLabels.removeFromSpace);
    await tester.scrollUntilVisible(remove, 200, scrollable: scroll);
    expect(tester.getRect(remove).bottom, lessThanOrEqualTo(viewport.height));
  });

  testWidgets('bot roles stay marked in the opened list', (tester) async {
    await _openSheet(tester);
    await tester.tap(find.text('Roles'));
    await tester.pumpAndSettle();
    expect(find.text('BOT'), findsNWidgets(7));
  });

  testWidgets('Remove confirms, then calls the remove route', (tester) async {
    final rig = await _openSheet(tester);
    await tester.tap(find.text(ActionLabels.removeFromSpace));
    await tester.pumpAndSettle();
    expect(rig.calls, isEmpty, reason: 'nothing happens before the confirm');
    expect(find.text('Remove maya from this Space?'), findsOneWidget);

    await tester.tap(find.widgetWithText(AppButton, 'Remove').last);
    await tester.pumpAndSettle();
    expect(rig.calls, ['PUT /members/user-maya/removal']);
  });

  testWidgets('without the ban right there is no Remove', (tester) async {
    await _openSheet(tester, permissions: Perm.kickMembers | Perm.sendMessages);
    expect(find.text('5m'), findsOneWidget);
    expect(find.text(ActionLabels.removeFromSpace), findsNothing);
  });

  testWidgets('dark theme keeps Remove inside the viewport', (tester) async {
    await _openSheet(tester, brightness: Brightness.dark);
    expect(
      tester.getRect(find.text(ActionLabels.removeFromSpace)).bottom,
      lessThanOrEqualTo(viewport.height),
    );
  });

  testWidgets('at desktop width every role keeps its toggle', (tester) async {
    await _openSheet(tester, size: const Size(1280, 900));
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(AppToggle), findsNWidgets(_roles.length));
    expect(find.text('Roles'), findsNothing);
    expect(find.text('ROLES'), findsOneWidget);
  });

  for (final (name, size, brightness) in [
    ('phone-dark', viewport, Brightness.dark),
    ('phone-light', viewport, Brightness.light),
    ('desktop-light', const Size(1280, 900), Brightness.light),
  ]) {
    testWidgets('capture $name', (tester) async {
      await _openSheet(tester, size: size, brightness: brightness);
      await writeSnapshot(tester, 'moderate-sheet-$name');
      if (size == viewport) {
        await tester.tap(find.text('Roles'));
        await tester.pumpAndSettle();
        await writeSnapshot(tester, 'moderate-sheet-$name-roles-open');
      }
    });
  }
}
