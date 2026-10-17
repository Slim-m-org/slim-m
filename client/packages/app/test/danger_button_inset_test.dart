// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Both destructive buttons on Account & devices sit the same distance from
/// their card's edge.
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

String _device(String id, {required bool current}) => jsonEncode({
  'id': id,
  'name': id,
  'created_at': 0,
  'last_seen_at': 0,
  'is_current': current,
});

/// Right inset of [label]'s button inside its section, whose width is its card's.
double _insetOf(WidgetTester tester, String label, Type section) {
  final button = tester.getRect(find.widgetWithText(AppButton, label));
  return tester.getRect(find.byType(section)).right - button.right;
}

void main() {
  testWidgets('sibling destructive buttons share one card inset', (
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
            httpClient: MockClient(
              (request) async => http.Response(
                '[${_device('this', current: true)},${_device('other', current: false)}]',
                200,
                headers: {'content-type': 'application/json'},
              ),
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
          home: const Scaffold(
            body: SingleChildScrollView(
              child: Column(children: [DevicesSection(), AccountSection()]),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      _insetOf(tester, 'Sign out others', DevicesSection),
      _insetOf(tester, 'Delete account...', AccountSection),
    );
  });
}
