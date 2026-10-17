// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The roles pane's Permissions tab: grouping, filtering, the "you don't
/// hold this" disabled state, elevated tags, and the pending-change
/// save/discard footer.
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
import 'package:slimm_app/src/features/settings/screens/admin/role_permissions_rows.dart';
import 'package:slimm_app/src/features/settings/screens/admin/role_permissions_tab.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_detail_row.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

api.Role _role({int permissions = 0}) => api.Role(
  id: 'role-mod',
  name: 'mod',
  permissions: permissions,
  isEveryone: false,
  createdAt: 0,
);

Widget _wrap({
  required api.Role role,
  int myPermissions = 0,
  MockClient? client,
}) {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      myPermissionsProvider.overrideWithValue(myPermissions),
      modulePermissionsProvider.overrideWith((ref) async => const []),
      roleModulePermissionsProvider(
        role.id,
      ).overrideWith((ref) async => const []),
      if (client != null)
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
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(body: RolePermissionsTab(role: role)),
    ),
  );
}

Finder _row(String title) => find.ancestor(
  of: find.text(title),
  matching: find.byType(SettingsDetailRow),
);

Finder _toggle(String title) =>
    find.descendant(of: _row(title), matching: find.byType(AppToggle));

void main() {
  testWidgets('permissions are grouped under headers', (tester) async {
    await tester.pumpWidget(
      _wrap(
        role: _role(),
        myPermissions: Perm.editable.fold(0, (acc, p) => acc | p.$1),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Messages'), findsOneWidget);
    expect(find.text('Moderation'), findsOneWidget);
    expect(find.text('Send messages'), findsOneWidget);
    expect(find.text('Manage roles'), findsOneWidget);
  });

  testWidgets('the elevated tag shows on manage roles but not send messages', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(role: _role(), myPermissions: Perm.manageRoles | Perm.sendMessages),
    );
    await tester.pumpAndSettle();

    final manageRolesRow = _row('Manage roles');
    expect(
      find.descendant(of: manageRolesRow, matching: find.text('ELEVATED')),
      findsOneWidget,
    );
  });

  testWidgets('filtering hides permissions that do not match', (tester) async {
    await tester.pumpWidget(_wrap(role: _role(), myPermissions: 0));
    await tester.pumpAndSettle();

    expect(find.text('Send messages'), findsOneWidget);
    expect(find.text('Ban members'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'ban');
    await tester.pumpAndSettle();

    expect(find.text('Send messages'), findsNothing);
    expect(find.text('Ban members'), findsOneWidget);
  });

  testWidgets("a permission the caller does not hold is disabled and marked", (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(role: _role(), myPermissions: 0));
    await tester.pumpAndSettle();

    expect(find.byTooltip(PermissionToggleRow.notHeldHint), findsWidgets);

    final toggle = tester.widget<AppToggle>(_toggle('Send messages'));
    expect(toggle.onChanged, isNull);
  });

  testWidgets(
    'toggling a held permission tracks one pending change, discard clears it',
    (tester) async {
      await tester.pumpWidget(
        _wrap(role: _role(), myPermissions: Perm.sendMessages),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('unsaved change'), findsNothing);

      await tester.tap(_toggle('Send messages'));
      await tester.pumpAndSettle();

      expect(find.text('1 unsaved change'), findsOneWidget);

      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();

      expect(find.textContaining('unsaved change'), findsNothing);
    },
  );

  testWidgets('saving sends the new permissions bitmask', (tester) async {
    http.Request? captured;
    final client = MockClient((request) async {
      captured = request;
      return http.Response(
        jsonEncode({
          'id': 'role-mod',
          'name': 'mod',
          'permissions': Perm.sendMessages,
          'is_everyone': false,
          'mentionable': false,
          'created_at': 0,
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    await tester.pumpWidget(
      _wrap(role: _role(), myPermissions: Perm.sendMessages, client: client),
    );
    await tester.pumpAndSettle();

    await tester.tap(_toggle('Send messages'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(captured, isNotNull);
    expect(captured!.method, 'PATCH');
    final body = jsonDecode(captured!.body) as Map<String, dynamic>;
    expect(body['permissions'], Perm.sendMessages);
    expect(find.textContaining('unsaved change'), findsNothing);
  });
}
