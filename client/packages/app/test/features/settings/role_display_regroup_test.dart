// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Saving "Display role members separately" refetches the member list even
/// when the role's own change event refreshes the tab before the save returns,
/// which used to make the tab think nothing had changed.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/settings/screens/admin/role_display_tab.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _role = api.Role(
  id: 'r1',
  name: 'crew',
  permissions: 0,
  isEveryone: false,
  createdAt: 0,
);

const _hoisted = api.Role(
  id: 'r1',
  name: 'crew',
  permissions: 0,
  isEveryone: false,
  createdAt: 0,
  hoist: true,
);

void main() {
  testWidgets('the roster refetches though the role refreshed mid-save', (
    tester,
  ) async {
    final patch = Completer<http.Response>();
    var rosterFetches = 0;
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        mockApiOverride((request) async {
          if (request.method == 'PATCH') return patch.future;
          if (request.url.path == '/members') rosterFetches++;
          return http.Response('[]', 200);
        }),
      ],
    );
    addTearDown(container.dispose);
    container.listen(membersProvider, (_, _) {});
    final role = ValueNotifier(_role);
    addTearDown(role.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: ValueListenableBuilder(
              valueListenable: role,
              builder: (_, value, _) => RoleDisplayTab(role: value),
            ),
          ),
        ),
      ),
    );
    await pumpFrames(tester);
    final before = rosterFetches;

    final toggle = find.descendant(
      of: find.ancestor(
        of: find.text('Display role members separately'),
        matching: find.byWidgetPredicate((w) => w is Row),
      ),
      matching: find.byWidgetPredicate((w) => w is AppToggle),
    );
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await pumpFrames(tester);
    await tester.tap(find.text('Save changes'));
    await pumpFrames(tester);

    role.value = _hoisted;
    await pumpFrames(tester);
    patch.complete(
      http.Response(
        jsonEncode({
          'id': 'r1',
          'name': 'crew',
          'permissions': 0,
          'is_everyone': false,
          'hoist': true,
          'created_at': 0,
        }),
        200,
      ),
    );
    await pumpFrames(tester);

    expect(rosterFetches, greaterThan(before));
  });
}
