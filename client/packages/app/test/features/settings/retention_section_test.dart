// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The retention control shows the window the server holds, including one set
/// outside the four presets.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/screens/admin/retention_section.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

const _tokens = api.TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Future<AppSegmentedControl> _pump(WidgetTester tester, int days) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        apiProvider.overrideWith((ref) {
          final built = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient(
              (_) async => http.Response(
                jsonEncode({'retention_days': days}),
                200,
                headers: {'content-type': 'application/json'},
              ),
            ),
          );
          ref.onDispose(built.close);
          return built;
        }),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: const Scaffold(
          body: SingleChildScrollView(child: RetentionSection()),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  return tester.widget<AppSegmentedControl>(
    find.byWidgetPredicate(
      (w) =>
          w is AppSegmentedControl &&
          w.semanticLabel == 'Message retention window',
    ),
  );
}

void main() {
  testWidgets('a window outside the presets gets its own selected segment', (
    tester,
  ) async {
    final control = await _pump(tester, 45);

    expect(control.options[control.selectedIndex].label, '45 days');
    expect(
      control.options.map((o) => o.label),
      containsAll(['Never', '30 days', '90 days', '365 days']),
    );
  });

  testWidgets('a preset window selects its own segment', (tester) async {
    final control = await _pump(tester, 90);

    expect(control.options[control.selectedIndex].label, '90 days');
    expect(control.options, hasLength(4));
  });

  testWidgets('no window selects Never', (tester) async {
    final control = await _pump(tester, 0);

    expect(control.options[control.selectedIndex].label, 'Never');
  });
}
