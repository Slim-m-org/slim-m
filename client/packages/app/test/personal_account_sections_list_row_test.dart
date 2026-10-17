// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `DevicesSection` and `BlockedSection` used to render their rows as bare
/// `ListTile`s: taller, differently inset, and with none of `AppListRow`'s
/// hover, press or keyboard-focus chrome. `AccountSection`'s own deletion row
/// has since moved off `AppListRow` entirely, onto an outlined danger button:
/// see its own test below.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/blocks_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/personal_account_sections.dart';
import 'package:slimm_app/src/widgets/settings_detail_row.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'support/fake_blocks.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

void main() {
  testWidgets(
    'DevicesSection rows are SettingsDetailRow, never a bare ListTile',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
          apiProvider.overrideWith((ref) {
            final api = SlimmApi(
              baseUrl: Uri.parse('http://localhost:8080'),
              session: ref.watch(sessionProvider),
              httpClient: MockClient(
                (request) async =>
                    request.method == 'GET' && request.url.path == '/devices'
                    ? http.Response(
                        jsonEncode([
                          {
                            'id': 'device-1',
                            'name': 'A phone',
                            'created_at': 0,
                            'last_seen_at': 0,
                            // Current: a lone other device would also draw the new bulk sign-out row, breaking this test's exactly-one-row count.
                            'is_current': true,
                          },
                        ]),
                        200,
                        headers: {'content-type': 'application/json'},
                      )
                    : http.Response('{}', 404),
              ),
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
            home: const Scaffold(body: DevicesSection()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ListTile), findsNothing);
      expect(find.byType(SettingsDetailRow), findsOneWidget);
    },
  );

  testWidgets('AccountSection renders deletion as an outlined danger button', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
        apiProvider.overrideWith((ref) {
          final api = SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient((request) async => http.Response('{}', 404)),
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

    expect(find.byType(ListTile), findsNothing);
    expect(find.byType(AppListRow), findsNothing);
    final button = tester.widget<AppButton>(
      find.widgetWithText(AppButton, 'Delete account...'),
    );
    expect(button.variant, AppButtonVariant.danger);
  });

  testWidgets(
    'BlockedSection rows are SettingsDetailRow, never a bare ListTile',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
          apiProvider.overrideWith((ref) {
            final api = SlimmApi(
              baseUrl: Uri.parse('http://localhost:8080'),
              session: ref.watch(sessionProvider),
              httpClient: MockClient((request) async {
                if (request.url.path == '/users') {
                  return http.Response(
                    jsonEncode([
                      {
                        'id': 'user-blocked',
                        'username': 'kit',
                        'display_name': 'Kit',
                        'created_at': 0,
                      },
                    ]),
                    200,
                    headers: {'content-type': 'application/json'},
                  );
                }
                return http.Response('{}', 404);
              }),
            );
            ref.onDispose(api.close);
            return api;
          }),
          blocksProvider.overrideWith(
            (ref) => FixedBlocksController(
              ref,
              const BlocksState(ids: {'user-blocked'}, settled: true),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: const Scaffold(body: BlockedSection()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ListTile), findsNothing);
      expect(find.byType(SettingsDetailRow), findsOneWidget);
      expect(find.text('Kit'), findsOneWidget);
      expect(find.widgetWithText(AppButton, 'Unblock'), findsOneWidget);
    },
  );
}
