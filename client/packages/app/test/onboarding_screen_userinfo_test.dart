// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Userinfo in a typed server address must never ride along on a probe or
/// survive into storage: dart:io turns it into a Basic auth header on every
/// request the stored base URL makes afterward. See reduceServerAddress.
///
/// Split out of onboarding_screen_test.dart to keep that file under the
/// review budget; see it for the rest of onboarding's identity coverage.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/onboarding_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

void main() {
  const typed = 'https://user:pass@chat.example/ignored?also=ignored';
  const reduced = 'https://chat.example';

  testWidgets(
    'is stripped before the manual dialog probes or persists the address',
    (tester) async {
      Uri? chosen;
      Uri? probedWith;
      final httpClient = MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/version') {
          return http.Response(
            jsonEncode(const {
              'name': 'slim-m',
              'version': '0.6.0',
              'protocol': 1,
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 200);
      });

      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          probeApiProvider.overrideWithValue((baseUrl) {
            probedWith = baseUrl;
            return SlimmApi(baseUrl: baseUrl, httpClient: httpClient);
          }),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: OnboardingScreen(
              onServerChosen: (server, invite) => chosen = server,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Connect to a Space'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), typed);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(probedWith, Uri.parse(reduced));
      expect(chosen, Uri.parse(reduced));
    },
  );

  testWidgets(
    'is stripped before the invite dialog probes or persists the address',
    (tester) async {
      Uri? chosen;
      Uri? probedWith;
      final httpClient = MockClient((request) async {
        if (request.method == 'GET' && request.url.path.endsWith('/check')) {
          return http.Response(
            jsonEncode(const {
              'usable': true,
              'community': {
                'name': 'Space',
                'member_count': 3,
                'invited_by': 'alice',
                'uses_remaining': null,
                'expires_at': null,
              },
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 200);
      });

      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          probeApiProvider.overrideWithValue((baseUrl) {
            probedWith = baseUrl;
            return SlimmApi(baseUrl: baseUrl, httpClient: httpClient);
          }),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: OnboardingScreen(
              onServerChosen: (server, invite) => chosen = server,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('I have an invite'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, typed);
      await tester.enterText(find.byType(TextField).at(1), 'CODE123');
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Join'));
      await tester.pumpAndSettle();

      expect(probedWith, Uri.parse(reduced));
      expect(chosen, Uri.parse(reduced));
    },
  );
}
