// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The role Display tab's "Display role members separately" toggle: it sends
/// `hoist` on its own, and `@everyone` has no such control.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/settings/screens/admin/role_display_tab.dart';
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
  testWidgets('the toggle sends hoist and nothing else', (tester) async {
    final patches = await _pump(
      tester,
      const api.Role(
        id: 'r1',
        name: 'Mod',
        permissions: 0,
        isEveryone: false,
        createdAt: 0,
      ),
    );

    final toggle = find.descendant(
      of: find.ancestor(
        of: find.text('Display role members separately'),
        matching: find.byType(Row),
      ),
      matching: find.byType(AppToggle),
    );
    expect(toggle, findsOneWidget);
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(patches, [
      {'hoist': true},
    ]);
  });

  testWidgets('the role name field is announced as the role name', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pump(
      tester,
      const api.Role(
        id: 'r1',
        name: 'Mod',
        permissions: 0,
        isEveryone: false,
        createdAt: 0,
      ),
    );

    expect(find.bySemanticsLabel('Role name'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('@everyone has no member-list control', (tester) async {
    await _pump(
      tester,
      const api.Role(
        id: 'r0',
        name: '@everyone',
        permissions: 0,
        isEveryone: true,
        createdAt: 0,
      ),
    );

    expect(find.text('Display role members separately'), findsNothing);
  });
}
