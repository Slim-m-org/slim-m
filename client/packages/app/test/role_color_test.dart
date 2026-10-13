// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The role Display tab's colour picker and how a role's colour is resolved.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'dart:ui' show Tristate;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/admin/role_display_tab.dart';
import 'package:slimm_app/src/widgets/role_color.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

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
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
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
        );
        ref.onDispose(client.close);
        return client;
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
    await tester.pumpAndSettle();
    expect(patches, [
      {'color': 9},
    ]);
  });

  testWidgets('an unchosen role shows its hashed colour as selected', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, role);
    final hashed = rolePalette[rolePaletteIndex(role.id, null)].name;
    final node = tester.getSemantics(
      find.bySemanticsLabel('Role colour: $hashed'),
    );
    expect(node.getSemanticsData().flagsCollection.isSelected, Tristate.isTrue);
    semantics.dispose();
  });

  test('a chosen colour wins over the hashed one, and junk falls back', () {
    expect(roleColor('r1', color: 6), rolePalette[6].color);
    expect(roleColor('r1', color: 42), roleColor('r1'));
    expect(roleColor('r1', color: -1), roleColor('r1'));
    expect(rolePalette, hasLength(api.InputLimits.roleColors));
  });
}
