// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The role Display tab's colour picker, its No colour swatch, and how a
/// role's colour is resolved.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'dart:ui' show Tristate;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/settings/screens/admin/role_display_tab.dart';
import 'package:slimm_app/src/features/members/widgets/role_color.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import '../../support/fake_api.dart';
import '../../support/async_wait.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Future<List<Map<String, dynamic>>> _pump(
  WidgetTester tester,
  api.Role role,
) async {
  final patches = <Map<String, dynamic>>[];
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      mockApiOverride((request) async {
        if (request.method == 'PATCH') {
          patches.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response(
            jsonEncode({
              'id': role.id,
              'name': role.name,
              'permissions': 0,
              'is_everyone': false,
              'mentionable': false,
              'hoist': true,
              'created_at': 0,
            }),
            200,
          );
        }
        return http.Response('[]', 200);
      }),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: RoleDisplayTab(role: role)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return patches;
}

void main() {
  const role = api.Role(
    id: 'r1',
    name: 'Mod',
    permissions: 0,
    isEveryone: false,
    createdAt: 0,
  );

  testWidgets('picking a swatch sends that palette index and nothing else', (
    tester,
  ) async {
    final patches = await _pump(tester, role);
    final teal = find.bySemanticsLabel('Role colour: Teal');
    await tester.ensureVisible(teal);
    await tester.tap(teal);
    await pumpFrames(tester);
    expect(patches, isEmpty);
    await tester.tap(find.widgetWithText(AppButton, 'Save changes'));
    await pumpFrames(tester);
    expect(patches, [
      {'color': 9},
    ]);
  });

  testWidgets('an unchosen role shows No colour as selected', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, role);
    final node = tester.getSemantics(
      find.bySemanticsLabel('Role colour: No colour'),
    );
    expect(node.getSemanticsData().flagsCollection.isSelected, Tristate.isTrue);
    semantics.dispose();
  });

  testWidgets('No colour clears a chosen colour with an explicit null', (
    tester,
  ) async {
    final patches = await _pump(
      tester,
      const api.Role(
        id: 'r1',
        name: 'Mod',
        permissions: 0,
        isEveryone: false,
        createdAt: 0,
        color: 6,
      ),
    );
    final none = find.bySemanticsLabel('Role colour: No colour');
    await tester.ensureVisible(none);
    await tester.tap(none);
    await tester.pump();
    await tester.tap(find.widgetWithText(AppButton, 'Save changes'));
    await tester.pumpAndSettle();
    expect(patches, [
      {'color': null},
    ]);
  });

  test(
    'only a chosen colour in range colours a role, else the neutral dot',
    () {
      expect(chosenRoleColor(6), rolePalette[6].color);
      expect(chosenRoleColor(42), isNull);
      expect(chosenRoleColor(-1), isNull);
      expect(roleDotColor(null, AppTokens.dark), AppTokens.dark.borderStrong);
      expect(roleDotColor(6, AppTokens.dark), rolePalette[6].color);
      expect(rolePalette, hasLength(api.InputLimits.roleColors));
    },
  );
}
