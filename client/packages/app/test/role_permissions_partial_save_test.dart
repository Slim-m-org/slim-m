// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A save that fails halfway keeps only the changes the server never took,
/// and still refreshes the role data it half changed.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/admin/role_permissions_tab.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

final _role = api.Role(
  id: 'role-mod',
  name: 'mod',
  permissions: 0,
  isEveryone: false,
  createdAt: 0,
);

http.Response _json(Object o, [int code = 200]) => http.Response(
  jsonEncode(o),
  code,
  headers: {'content-type': 'application/json'},
);

Finder _toggleIn(String label) => find.descendant(
  of: find.ancestor(of: find.text(label), matching: find.byType(Padding)).first,
  matching: find.byType(AppToggle),
);

void main() {
  testWidgets('a half-failed save drops what landed and refetches the role', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var roleFetches = 0;
    final client = MockClient((request) async {
      if (request.method == 'PATCH') {
        return _json({
          'id': 'role-mod',
          'name': 'mod',
          'permissions': Perm.sendMessages,
          'is_everyone': false,
          'mentionable': false,
          'created_at': 0,
        });
      }
      if (request.method == 'PUT' && request.url.path.endsWith('/a')) {
        return http.Response('', 204);
      }
      return _json({'error': 'boom'}, 500);
    });
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        myPermissionsProvider.overrideWithValue(Perm.sendMessages),
        rolesProvider.overrideWith((ref) async {
          roleFetches++;
          return [_role];
        }),
        modulePermissionsProvider.overrideWith(
          (ref) async => [
            for (final k in ['a', 'b'])
              api.ModulePermission(
                moduleId: 'm1',
                moduleName: 'Mod 1',
                permKey: k,
                name: 'Perm $k',
                description: 'd',
              ),
          ],
        ),
        roleModulePermissionsProvider(
          _role.id,
        ).overrideWith((ref) async => const []),
        apiProvider.overrideWith((ref) {
          final built = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: client,
          );
          ref.onDispose(built.close);
          return built;
        }),
      ],
    );
    addTearDown(container.dispose);
    container.listen(rolesProvider, (_, _) {});
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(body: RolePermissionsTab(role: _role)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(_toggleIn('Send messages'));
    await tester.tap(_toggleIn('Perm a'));
    await tester.tap(_toggleIn('Perm b'));
    await tester.pumpAndSettle();
    expect(find.text('3 unsaved changes'), findsOneWidget);
    final before = roleFetches;

    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(find.text('1 unsaved change'), findsOneWidget);
    expect(roleFetches, greaterThan(before));
  });
}
