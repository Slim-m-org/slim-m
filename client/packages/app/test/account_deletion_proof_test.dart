// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Deleting an account asks for proof (decision 0048): the password, and a
/// current code while two-factor is on. A session token alone is not enough.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/settings/widgets/personal_account_sections.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

http.Response _totpStatus({bool enabled = false}) => http.Response(
  jsonEncode({
    'enabled': enabled,
    'pending': false,
    'recovery_codes_remaining': 0,
    'policy': 'optional',
    'confirmed_at': null,
  }),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  /// A session token alone must not delete an account: the request carries
  /// the password, and the code while two-factor is on, and a refused
  /// password stays on the sheet instead of closing it.
  Future<List<Map<String, dynamic>>> deleteWith(
    WidgetTester tester, {
    required bool twoFactor,
    required int deleteStatus,
    required List<String> typed,
  }) async {
    final sent = <Map<String, dynamic>>[];
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
        apiProvider.overrideWith((ref) {
          final api = SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient((request) async {
              if (request.url.path == '/auth/totp') {
                return _totpStatus(enabled: twoFactor);
              }
              if (request.method == 'DELETE' &&
                  request.url.path == '/account') {
                sent.add(jsonDecode(request.body) as Map<String, dynamic>);
                return http.Response(
                  jsonEncode({'error': 'that password is not correct'}),
                  deleteStatus,
                  headers: {'content-type': 'application/json'},
                );
              }
              return http.Response('', 204);
            }),
          );
          ref.onDispose(api.close);
          return api;
        }),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(body: AccountSection()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete account...'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete permanently'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNWidgets(typed.length));
    for (var i = 0; i < typed.length; i++) {
      await tester.enterText(find.byType(TextField).at(i), typed[i]);
    }
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AppButton, 'Delete permanently'));
    await tester.pumpAndSettle();
    return sent;
  }

  testWidgets('deletion sends the password', (tester) async {
    final sent = await deleteWith(
      tester,
      twoFactor: false,
      deleteStatus: 204,
      typed: ['correct horse'],
    );
    expect(sent, [
      {'password': 'correct horse'},
    ]);
  });

  testWidgets('deletion also sends a code while two-factor is on', (
    tester,
  ) async {
    final sent = await deleteWith(
      tester,
      twoFactor: true,
      deleteStatus: 204,
      typed: ['correct horse', '123 456'],
    );
    expect(sent, [
      {'password': 'correct horse', 'code': '123456'},
    ]);
  });

  testWidgets('a refused password stays on the sheet with the reason', (
    tester,
  ) async {
    await deleteWith(
      tester,
      twoFactor: false,
      deleteStatus: 403,
      typed: ['wrong'],
    );
    expect(find.text('That password is not correct.'), findsOneWidget);
    expect(find.byType(AppErrorState), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(
      find.widgetWithText(AppButton, 'Delete permanently'),
      findsOneWidget,
      reason: 'the sheet is still open to retry from',
    );
  });
}
