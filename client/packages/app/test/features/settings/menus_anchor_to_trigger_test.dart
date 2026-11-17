// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A menu opened from a settings control sits beside that control on a wide
/// window instead of floating at the middle of it.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/members/widgets/avatar_settings_section.dart';
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

void main() {
  testWidgets('the profile picture menu opens beside the Change button', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
        mockApiOverride((request) async {
          if (request.url.path == '/me') {
            return http.Response(
              jsonEncode({
                'id': 'self',
                'username': 'self',
                'display_name': 'Self',
                'created_at': 0,
                'permissions': 0,
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response('', 404);
        }),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(body: AvatarSettingsSection()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final button = tester.getRect(
      find.bySemanticsLabel('Change profile picture'),
    );
    await tester.tap(find.bySemanticsLabel('Change profile picture'));
    await tester.pumpAndSettle();

    final menu = tester.getRect(find.text('Choose photo'));
    expect((menu.center - button.center).distance, lessThan(300));
  });
}
