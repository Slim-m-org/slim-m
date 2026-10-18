// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Each expiry choice on the new invite card sends the matching expires_at.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/action_labels.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/settings/screens/admin/invites_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import '../../support/fake_api.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);
const _json = {'content-type': 'application/json'};

Future<List<Map<String, dynamic>>> _create(
  WidgetTester tester,
  String? expiryLabel,
) async {
  final posts = <Map<String, dynamic>>[];
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      myPermissionsProvider.overrideWithValue(Perm.createInvite),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      mockApiOverride((request) async {
        if (request.method == 'POST') {
          posts.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response(
            jsonEncode({
              'code': 'fresh',
              'max_uses': null,
              'uses': 0,
              'expires_at': null,
              'created_at': 0,
              'revoked': false,
              'usable': true,
            }),
            200,
            headers: _json,
          );
        }
        return http.Response('[]', 200, headers: _json);
      }),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const InvitesScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (expiryLabel != null) await tester.tap(find.text(expiryLabel));
  await tester.tap(find.text(ActionLabels.createInvite));
  await tester.pumpAndSettle();
  return posts;
}

void main() {
  testWidgets('Never expires sends no expiry', (tester) async {
    expect(await _create(tester, null), [<String, dynamic>{}]);
  });

  const choices = {
    '1 day': Duration(days: 1),
    '7 days': Duration(days: 7),
    '30 days': Duration(days: 30),
  };
  for (final entry in choices.entries) {
    testWidgets('${entry.key} sends an expiry that far ahead', (tester) async {
      final before = DateTime.now().add(entry.value).millisecondsSinceEpoch;
      final posts = await _create(tester, entry.key);
      final after = DateTime.now().add(entry.value).millisecondsSinceEpoch;

      final sent = posts.single['expires_at'] as int;
      expect(sent, inInclusiveRange(before, after));
    });
  }
}
