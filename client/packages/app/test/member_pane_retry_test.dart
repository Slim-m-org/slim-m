// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/member_pane.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

void main() {
  for (final channel in <String?>[null, 'c1']) {
    testWidgets('Retry with channelId=$channel refetches the roster', (
      tester,
    ) async {
      var memberCalls = 0;
      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
          apiProvider.overrideWith((ref) {
            final client = SlimmApi(
              baseUrl: Uri.parse('http://localhost:8080'),
              session: ref.watch(sessionProvider),
              httpClient: MockClient((request) async {
                final path = request.url.path;
                if (path == '/me') {
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
                if (path == '/presence') return http.Response('[]', 200);
                memberCalls++;
                if (memberCalls == 1) {
                  return http.Response(jsonEncode({'error': 'x'}), 500);
                }
                return http.Response(
                  jsonEncode([
                    {
                      'id': '1',
                      'username': 'priya',
                      'display_name': 'Priya',
                      'created_at': 0,
                    },
                  ]),
                  200,
                );
              }),
            );
            ref.onDispose(client.close);
            return client;
          }),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: Scaffold(body: AppMemberPane(channelId: channel)),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Could not load members.'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Priya'), findsOneWidget);
    });
  }
}
