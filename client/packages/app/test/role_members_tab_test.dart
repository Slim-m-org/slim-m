// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The roles pane's Members tab: bots and people grouped separately, a long
/// group collapses to a "+N more" summary, the empty state, and search to
/// add.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/member_presence.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/admin/role_members_tab.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _roleId = 'role-mod';

api.UserProfile _member(
  String id,
  String name, {
  bool isBot = false,
  bool holds = true,
}) => api.UserProfile(
  id: id,
  username: name,
  displayName: name,
  createdAt: 0,
  isBot: isBot,
  roleIds: holds ? const [_roleId] : const [],
);

Widget _wrap(List<api.UserProfile> members) {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      membersProvider.overrideWith((ref) async => members),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(
        body: RoleMembersTab(
          role: const api.Role(
            id: _roleId,
            name: 'mod',
            permissions: 0,
            isEveryone: false,
            createdAt: 0,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('holders split into bots and people groups', (tester) async {
    await tester.pumpWidget(
      _wrap([_member('b1', 'sample_bot', isBot: true), _member('p1', 'Kiki')]),
    );
    await tester.pumpAndSettle();

    expect(find.text('Bots · 1'), findsOneWidget);
    expect(find.text('People · 1'), findsOneWidget);
    expect(find.text('sample_bot'), findsOneWidget);
    expect(find.text('Kiki'), findsOneWidget);
  });

  testWidgets(
    'a bot holder with no picture shows initials, not a blank square',
    (tester) async {
      await tester.pumpWidget(
        _wrap([_member('b1', 'sample_bot', isBot: true)]),
      );
      await tester.pumpAndSettle();

      // initialsFor strips symbols and uppercases the first two characters.
      expect(find.text('SA'), findsOneWidget);
    },
  );

  testWidgets('a bot search candidate with no picture shows initials too', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap([_member('b1', 'sample_bot', isBot: true, holds: false)]),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'sample');
    await tester.pumpAndSettle();

    expect(find.text('SA'), findsOneWidget);
  });

  testWidgets('the empty group shows its message', (tester) async {
    await tester.pumpWidget(_wrap([_member('b1', 'sample_bot', isBot: true)]));
    await tester.pumpAndSettle();

    expect(find.text('No people hold this role'), findsOneWidget);
    expect(find.text('Search above to add someone.'), findsOneWidget);
  });

  testWidgets('a group past five collapses to a "+more" summary', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap([for (var i = 0; i < 8; i++) _member('p$i', 'person$i')]),
    );
    await tester.pumpAndSettle();

    expect(find.text('People · 8'), findsOneWidget);
    expect(find.text('person0'), findsOneWidget);
    expect(find.text('person4'), findsOneWidget);
    expect(find.text('person5'), findsNothing);
    expect(find.textContaining('+ 3 more'), findsOneWidget);

    await tester.tap(find.textContaining('+ 3 more'));
    await tester.pumpAndSettle();

    expect(find.text('person5'), findsOneWidget);
    expect(find.text('person7'), findsOneWidget);
  });

  testWidgets('searching shows candidates who do not already hold the role', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap([_member('p1', 'Kiki'), _member('p2', 'Nadia', holds: false)]),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'nad');
    await tester.pumpAndSettle();

    expect(find.text('Nadia'), findsOneWidget);
    // Kiki already holds the role, so is never offered as a candidate to add.
    expect(find.textContaining('⏎ add'), findsOneWidget);
  });
}
