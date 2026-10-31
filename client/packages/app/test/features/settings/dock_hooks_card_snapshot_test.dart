// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Capture helper, asserts nothing: the Checks card on a module's Dock page at a phone and a
/// desktop width, light and dark. PNGs are written only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/screens/admin/dock_hooks_card.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../ui_snapshot_support.dart';

Map<String, Object?> _hook(
  String hook,
  String phase, {
  String kind = 'interceptor',
  int failures = 0,
  bool failClosed = false,
  bool live = true,
}) => {
  'module_id': 'filter',
  'module_name': 'Word filter',
  'kind': kind,
  'hook': hook,
  'phase': phase,
  'reads': ['content'],
  'priority': 100,
  'fail_closed': failClosed,
  'live': live,
  'runs': 42,
  'failures': failures,
  'last_error': failures == 0 ? null : 'the module trapped',
  'max_fuel_used': 1200,
};

/// Lets the mocked round trip resolve, then the rebuild after it.
Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  setUpAll(loadRealFonts);

  final hooks = [
    _hook('message.pre_send', 'reject', failures: 2, failClosed: true),
    _hook('message.pre_edit', 'rewrite'),
    _hook('message.send', '', kind: 'permission', live: false),
  ];

  for (final (width, label) in const [(390.0, 'phone'), (1280.0, 'desktop')]) {
    for (final dark in const [false, true]) {
      final mode = dark ? 'dark' : 'light';
      testWidgets('checks card, $label, $mode', (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final tokens = dark ? AppTokens.dark : AppTokens.light;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
              sessionProvider.overrideWithValue(
                api.SessionStore(
                  tokens: const api.TokenPair(
                    userId: 'admin',
                    accessToken: 'a',
                    refreshToken: 'r',
                    accessExpiresAt: 0,
                  ),
                ),
              ),
              apiProvider.overrideWith((ref) {
                final built = api.SlimmApi(
                  baseUrl: Uri.parse('http://localhost:8080'),
                  session: ref.watch(sessionProvider),
                  httpClient: MockClient(
                    (_) async => http.Response(
                      jsonEncode(hooks),
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
              theme: buildTheme(
                dark ? Brightness.dark : Brightness.light,
                tokens,
              ),
              home: RepaintBoundary(
                key: snapshotBoundary,
                child: Scaffold(
                  backgroundColor: tokens.surfaceBase,
                  body: const SingleChildScrollView(
                    padding: EdgeInsets.all(AppSpacing.s16),
                    child: DockHooksCard(moduleId: 'filter'),
                  ),
                ),
              ),
            ),
          ),
        );
        await _settle(tester);
        await writeSnapshot(tester, 'dock-hooks-card-$label-$mode');
      });
    }
  }
}
