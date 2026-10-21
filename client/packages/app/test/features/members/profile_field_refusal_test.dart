// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A refused About or Pronouns save says why under the field. It used to be
/// swallowed, so text the server would not take (an emoji it refused) just
/// sat there unsaved with nothing telling anyone.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/members/widgets/profile_fields_section.dart';
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

const _refusal = 'about can be at most 5 lines';

Future<void> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(900, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      mockApiOverride((request) async {
        const json = {'content-type': 'application/json'};
        if (request.url.path != '/me') return http.Response('', 404);
        if (request.method == 'PATCH') {
          return http.Response(
            jsonEncode({'error': _refusal}),
            400,
            headers: json,
          );
        }
        return http.Response(
          jsonEncode({
            'id': 'self',
            'username': 'nc1107',
            'display_name': 'Nick',
            'created_at': 0,
            'permissions': 0,
          }),
          200,
          headers: json,
        );
      }),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: SingleChildScrollView(child: ProfileFieldsSection()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a refused About save shows the reason under the field', (
    tester,
  ) async {
    await _pump(tester);

    await tester.tap(find.byType(TextField).last);
    await tester.enterText(find.byType(TextField).last, '1\n2\n3\n4\n5\n6');
    await tester.tap(find.byType(TextField).first);
    await tester.pumpAndSettle();

    expect(find.textContaining(_refusal), findsOneWidget);
  });

  testWidgets('typing again clears the refusal', (tester) async {
    await _pump(tester);

    await tester.tap(find.byType(TextField).last);
    await tester.enterText(find.byType(TextField).last, 'too\nmany');
    await tester.tap(find.byType(TextField).first);
    await tester.pumpAndSettle();
    expect(find.textContaining(_refusal), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, 'fixed');
    await tester.pumpAndSettle();
    expect(find.textContaining(_refusal), findsNothing);
  });
}
