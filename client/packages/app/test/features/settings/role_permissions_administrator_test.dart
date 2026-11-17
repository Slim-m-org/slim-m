// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Administrator on a role shows every permission below it as granted, and
/// turning it off shows the role's own saved values again. Only the
/// Administrator bit itself is ever saved.
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
import 'package:slimm_app/src/features/settings/screens/admin/role_permissions_tab.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _role = api.Role(
  id: 'role-mod',
  name: 'mod',
  permissions: Perm.sendMessages,
  isEveryone: false,
  createdAt: 0,
);

Future<void> _pump(WidgetTester tester, MockClient client) async {
  tester.view.physicalSize = const Size(1280, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      myPermissionsProvider.overrideWithValue(
        Perm.editable.fold(Perm.administrator, (acc, p) => acc | p.$1),
      ),
      modulePermissionsProvider.overrideWith((ref) async => const []),
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
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: RolePermissionsTab(role: _role)),
      ),
    ),
  );
  await pumpFrames(tester);
}

AppToggle _toggle(WidgetTester tester, String label) => tester.widget(
  find.byWidgetPredicate((w) => w is AppToggle && w.semanticLabel == label),
);

Future<void> _tapAdministrator(WidgetTester tester) async {
  await tester.tap(
    find.byWidgetPredicate(
      (w) => w is AppToggle && w.semanticLabel == 'Administrator',
    ),
  );
  await pumpFrames(tester);
}

void main() {
  testWidgets('Administrator on shows every permission granted and locked; '
      'off shows the role\'s own values again', (tester) async {
    await _pump(tester, MockClient((_) async => http.Response('{}', 500)));

    expect(_toggle(tester, 'Send messages').value, isTrue);
    expect(_toggle(tester, 'Ban members').value, isFalse);
    expect(_toggle(tester, 'Ban members').onChanged, isNotNull);

    await _tapAdministrator(tester);

    for (final label in ['Send messages', 'Ban members', 'Manage roles']) {
      expect(_toggle(tester, label).value, isTrue, reason: label);
      expect(_toggle(tester, label).onChanged, isNull, reason: label);
    }
    expect(find.text(grantedByAdministrator), findsWidgets);

    await _tapAdministrator(tester);

    expect(_toggle(tester, 'Send messages').value, isTrue);
    expect(_toggle(tester, 'Ban members').value, isFalse);
    expect(_toggle(tester, 'Ban members').onChanged, isNotNull);
    expect(find.text(grantedByAdministrator), findsNothing);
  });

  testWidgets(
    'saving with Administrator on writes only the Administrator bit',
    (tester) async {
      http.Request? captured;
      await _pump(
        tester,
        MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({
              'id': _role.id,
              'name': _role.name,
              'permissions': Perm.sendMessages | Perm.administrator,
              'is_everyone': false,
              'mentionable': false,
              'created_at': 0,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      await _tapAdministrator(tester);
      await tester.tap(find.text('Save changes'));
      await pumpFrames(tester);

      final body = jsonDecode(captured!.body) as Map<String, dynamic>;
      expect(body['permissions'], Perm.sendMessages | Perm.administrator);
    },
  );
}
