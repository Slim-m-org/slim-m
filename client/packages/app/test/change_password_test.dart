// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Changing your own password asks for the current one and the new one twice,
/// with the sign-up rule, and a code while two-factor is on.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/change_password_section.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

void main() {
  Future<List<Map<String, dynamic>>> open(
    WidgetTester tester, {
    required bool twoFactor,
    int status = 204,
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
                return http.Response(
                  jsonEncode({
                    'enabled': twoFactor,
                    'pending': false,
                    'recovery_codes_remaining': 0,
                    'policy': 'optional',
                    'confirmed_at': null,
                  }),
                  200,
                  headers: {'content-type': 'application/json'},
                );
              }
              if (request.url.path == '/auth/password') {
                sent.add(jsonDecode(request.body) as Map<String, dynamic>);
                return http.Response(
                  jsonEncode({'error': 'that password is not correct'}),
                  status,
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
          home: const Scaffold(body: ChangePasswordSection()),
        ),
      ),
    );
    await tester.tap(find.text('Change password'));
    await tester.pumpAndSettle();
    return sent;
  }

  Future<void> type(WidgetTester tester, List<String> values) async {
    for (var i = 0; i < values.length; i++) {
      await tester.enterText(find.byType(TextField).at(i), values[i]);
    }
    await tester.pumpAndSettle();
  }

  AppButton submit(WidgetTester tester) => tester.widget<AppButton>(
    find.widgetWithText(AppButton, 'Change password'),
  );

  testWidgets('the button waits for a valid, matching new password', (
    tester,
  ) async {
    await open(tester, twoFactor: false);
    expect(submit(tester).disabled, isTrue);

    await type(tester, ['old-password', 'short', 'short']);
    expect(submit(tester).disabled, isTrue, reason: 'under 8 characters');

    await type(tester, ['old-password', 'long-enough-1', 'long-enough-2']);
    expect(submit(tester).disabled, isTrue, reason: 'does not match');
    expect(find.text('The passwords do not match.'), findsOneWidget);

    await type(tester, ['old-password', 'long-enough-1', 'long-enough-1']);
    expect(submit(tester).disabled, isFalse);
  });

  testWidgets('it sends the current and new password', (tester) async {
    final sent = await open(tester, twoFactor: false);
    expect(find.byType(TextField), findsNWidgets(3));
    await type(tester, ['old-password', 'long-enough-1', 'long-enough-1']);
    await tester.tap(find.widgetWithText(AppButton, 'Change password'));
    await tester.pumpAndSettle();

    expect(sent, [
      {'current_password': 'old-password', 'new_password': 'long-enough-1'},
    ]);
    expect(find.text('Password changed.'), findsOneWidget);
  });

  testWidgets('it also sends a code while two-factor is on', (tester) async {
    final sent = await open(tester, twoFactor: true);
    expect(find.byType(TextField), findsNWidgets(4));
    await type(tester, [
      'old-password',
      'long-enough-1',
      'long-enough-1',
      '123456',
    ]);
    await tester.tap(find.widgetWithText(AppButton, 'Change password'));
    await tester.pumpAndSettle();

    expect(sent.single['code'], '123456');
  });

  testWidgets('a wrong current password stays on the sheet', (tester) async {
    await open(tester, twoFactor: false, status: 403);
    await type(tester, ['old-password', 'long-enough-1', 'long-enough-1']);
    await tester.tap(find.widgetWithText(AppButton, 'Change password'));
    await tester.pumpAndSettle();

    expect(find.text('That password is not correct.'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(3));
    expect(find.text('Password changed.'), findsNothing);
  });
}
