// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The About pencil on your own card opens profile settings with the About
/// field focused; the field is where the bio is edited.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/widgets/profile_fields_section.dart';
import 'package:slimm_app/src/features/members/widgets/member_profile.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/fake_api.dart';

const _me = api.Me(
  id: 'me',
  username: 'me',
  displayName: 'Me',
  createdAt: 0,
  permissions: 0,
  about: 'Straight Ballin',
);

const _profile = api.UserProfile(
  id: 'me',
  username: 'me',
  displayName: 'Me',
  createdAt: 0,
  about: 'Straight Ballin',
);

void main() {
  testWidgets('the pencil on your card opens profile settings at About', (
    tester,
  ) async {
    String? opened;
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(
            body: SingleChildScrollView(
              child: MemberProfileBody(
                profile: _profile,
                compact: false,
                onDone: () {},
              ),
            ),
          ),
        ),
        GoRoute(
          path: Routes.personalSettings,
          builder: (_, state) {
            opened = state.uri.toString();
            return const SizedBox();
          },
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [meProvider.overrideWith((ref) async => _me)],
        child: MaterialApp.router(
          routerConfig: router,
          theme: buildTheme(Brightness.light, AppTokens.light),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.bySemanticsLabel('Edit about'));
    await tester.pump(const Duration(milliseconds: 100));

    expect(opened, Routes.personalSettingsAbout());
    expect(opened, contains('focus=about'));
  });

  testWidgets('the About field takes focus when asked to', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [meProvider.overrideWith((ref) async => _me)],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(
            body: SingleChildScrollView(
              child: ProfileFieldsSection(focusAbout: true),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    // Pronouns comes first, so About is the last field in the section.
    final field = tester.widget<EditableText>(
      find.byWidgetPredicate((w) => w is EditableText).last,
    );
    expect(field.focusNode.hasFocus, isTrue);
  });

  testWidgets('leaving while About is still focused saves what was typed', (
    tester,
  ) async {
    final patches = <Map<String, dynamic>>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(
            api.SessionStore(
              tokens: const api.TokenPair(
                userId: 'me',
                accessToken: 'a',
                refreshToken: 'r',
                accessExpiresAt: 0,
              ),
            ),
          ),
          meProvider.overrideWith((ref) async => _me),
          mockApiOverride((request) async {
            if (request.method == 'PATCH' && request.url.path == '/me') {
              patches.add(jsonDecode(request.body) as Map<String, dynamic>);
            }
            return http.Response(
              jsonEncode({
                'id': 'me',
                'username': 'me',
                'display_name': 'Me',
                'created_at': 0,
                'permissions': 0,
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(
            body: SingleChildScrollView(
              child: ProfileFieldsSection(focusAbout: true),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(
      find.byWidgetPredicate((w) => w is EditableText).last,
      'Typed just before leaving',
    );
    await tester.pump();

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 100));

    expect(patches, [
      {'about': 'Typed just before leaving'},
    ]);
  });
}
