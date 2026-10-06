// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/reauth_sheet.dart';
import 'package:slimm_app/src/widgets/totp_section.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'user-1',
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  accessExpiresAt: 0,
);

void main() {
  testWidgets('policy off hides the section even with an abandoned enrolment', (
    tester,
  ) async {
    final json = {'content-type': 'application/json'};
    final client = MockClient((request) async {
      final path = request.url.path;
      if (request.method == 'GET' && path == '/auth/totp') {
        return http.Response(
          jsonEncode({
            'enabled': false,
            'pending': true,
            'recovery_codes_remaining': 0,
            'policy': 'off',
            'confirmed_at': null,
          }),
          200,
          headers: json,
        );
      }
      if (request.method == 'POST' && path == '/auth/totp/enrol') {
        // Exactly what enrolment_error(PolicyForbids) answers.
        return http.Response(
          jsonEncode({
            'error': 'this server does not accept new two-factor enrolments',
          }),
          403,
          headers: json,
        );
      }
      return http.Response('{}', 404, headers: json);
    });
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
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
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: const Scaffold(
            body: SingleChildScrollView(child: TotpSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Finish setting up'), findsNothing);
  });

  test('a 403 that is not about the password is not called a bad password', () {
    const refusal = api.ForbiddenException(
      'this server does not accept new two-factor enrolments',
    );
    expect(reauthFailure(refusal), refusal.message);
    expect(
      reauthFailure(
        const api.ForbiddenException('that password is not correct'),
      ),
      'That password is not correct.',
    );
  });
}
