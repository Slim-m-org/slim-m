// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The member pane has no close control of its own: the header's members
/// button toggles it.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/members/widgets/member_pane.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/fake_api.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Future<void> _pump(WidgetTester tester) async {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      mockApiOverride((request) async {
        if (request.url.path == '/me') {
          return http.Response(
            jsonEncode({
              'id': 'self',
              'username': 'self',
              'display_name': 'Self',
              'created_at': 0,
              'permissions': 0,
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
        home: const Scaffold(body: AppMemberPane(channelId: 'c1')),
      ),
    ),
  );
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('the pane header carries no close control', (tester) async {
    await _pump(tester);

    expect(find.bySemanticsLabel('Close member list'), findsNothing);
    expect(find.byIcon(AppIcons.dismiss), findsNothing);
  });
}
