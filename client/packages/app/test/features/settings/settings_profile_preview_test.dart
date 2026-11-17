// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The "How others see you" card follows the unsaved pronouns and about text
/// and the saved profile colour, without waiting for a blur save.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/members/widgets/profile_fields_section.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_profile_preview.dart';
import 'package:slimm_app/src/features/members/widgets/profile_banner.dart';
import 'package:slimm_app/src/features/members/widgets/role_color.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import '../../support/fake_api.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Future<void> _pumpPreview(WidgetTester tester, {Object? users}) async {
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      mockApiOverride((request) async {
        final body = switch (request.url.path) {
          '/me' => {
            'id': 'self',
            'username': 'nc1107',
            'display_name': 'Nick',
            'created_at': 0,
            'permissions': 0,
            'profile_color': 3,
          },
          '/users' => users,
          _ => null,
        };
        return http.Response(
          jsonEncode(body),
          body == null ? 404 : 200,
          headers: {'content-type': 'application/json'},
        );
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
}

void main() {
  testWidgets('typing pronouns and about updates the preview live', (
    tester,
  ) async {
    await _pumpPreview(tester);

    expect(find.text('@nc1107'), findsOneWidget);
    final banner = tester.widget<ProfileBanner>(
      find.byWidgetPredicate((w) => w is ProfileBanner),
    );
    expect(banner.colour, AppCanvasColors.cursors[3]);

    await tester.enterText(find.byType(EditableText).at(0), 'she/her');
    await tester.enterText(find.byType(EditableText).at(1), 'Hello there');
    await tester.pump();

    expect(find.textContaining('she/her', findRichText: true), findsWidgets);
    expect(find.text('Hello there'), findsNWidgets(2));
    expect(find.text('11 / 190'), findsOneWidget);
  });

  testWidgets('roles and the name look the way the profile card draws them', (
    tester,
  ) async {
    await _pumpPreview(
      tester,
      users: [
        {
          'id': 'self',
          'username': 'nc1107',
          'display_name': 'Nick',
          'created_at': 0,
          'roles': ['admin', 'Moderators'],
          'role_ids': ['r-admin', 'r-mod'],
          'role_colors': [null, 3],
        },
      ],
    );

    expect(find.text('ROLES'), findsOneWidget);
    expect(find.text('admin'), findsOneWidget);
    expect(find.text('Moderators'), findsOneWidget);
    expect(find.text('ADMIN'), findsNothing);
    final name = tester.widget<Text>(find.text('Nick').first);
    expect(name.style?.color, isNot(AppTokens.dark.textPrimary));
    expect(
      name.style?.color,
      memberNameColor(
        const UserProfile(
          id: 'self',
          username: 'nc1107',
          displayName: 'Nick',
          createdAt: 0,
          roleColors: [null, 3],
        ),
        AppTokens.dark.surfaceRaised,
      ),
    );
  });
}
