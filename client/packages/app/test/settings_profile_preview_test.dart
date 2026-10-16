// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The "How others see you" card follows the unsaved pronouns and about text
/// and the saved profile colour, without waiting for a blur save.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/profile_fields_section.dart';
import 'package:slimm_app/src/widgets/settings_profile_preview.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

void main() {
  testWidgets('typing pronouns and about updates the preview live', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
        apiProvider.overrideWith((ref) {
          final api = SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient((request) async {
              final body = switch (request.url.path) {
                '/me' => {
                  'id': 'self',
                  'username': 'nc1107',
                  'display_name': 'Nick',
                  'created_at': 0,
                  'permissions': 0,
                  'profile_color': 3,
                },
                _ => null,
              };
              return http.Response(
                jsonEncode(body),
                body == null ? 404 : 200,
                headers: {'content-type': 'application/json'},
              );
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
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: const Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [SettingsProfilePreview(), ProfileFieldsSection()],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('@nc1107'), findsOneWidget);
    final banner = tester.widget<Container>(
      find.byKey(const Key('profile-preview-banner')),
    );
    expect(banner.color, AppCanvasColors.cursors[3]);

    await tester.enterText(find.byType(EditableText).at(0), 'she/her');
    await tester.enterText(find.byType(EditableText).at(1), 'Hello there');
    await tester.pump();

    expect(find.textContaining('she/her', findRichText: true), findsWidgets);
    expect(find.text('Hello there'), findsNWidgets(2));
    expect(find.text('11 / 190'), findsOneWidget);
  });
}
