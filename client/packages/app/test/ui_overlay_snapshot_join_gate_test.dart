// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The join gate as people see it: the admin section, the banner above the
/// shell, and the rules sheet, at desktop and phone width.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/join_gate_section.dart';
import 'package:slimm_app/src/widgets/rules_gate_banner_host.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'support/mid_flight_capture.dart';
import 'ui_snapshot_support.dart';

const _desktop = Size(1280, 800);
const _phone = Size(390, 844);
const _json = {'content-type': 'application/json'};
const _rules =
    'Be kind, and assume good intent.\n'
    'No spam, ads or self-promotion without asking.\n'
    'Keep spoilers in #spoilers.\n'
    'Ask a moderator if you are unsure.';

const _tokens = api.TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

final _client = MockClient((request) async {
  final body = switch (request.url.path) {
    '/space/join-gate' => {
      'enabled': true,
      'rules': _rules,
      'rules_channel_id': 'c-rules',
      'joins_paused': false,
    },
    '/space/rules' => {
      'rules': _rules,
      'rules_channel_id': 'c-rules',
      'pending': true,
    },
    '/channels' => [
      {'id': 'c-rules', 'name': 'rules', 'kind': 'text', 'created_at': 1},
      {'id': 'c-general', 'name': 'general', 'kind': 'text', 'created_at': 1},
    ],
    _ => null,
  };
  return body == null
      ? http.Response('{}', 404, headers: _json)
      : http.Response(jsonEncode(body), 200, headers: _json);
});

Future<void> _pump(WidgetTester tester, Size size, Widget home) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      apiProvider.overrideWith(
        (ref) => api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: _client,
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: home,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _finish(WidgetTester tester, String name) async {
  await expectSettled(tester, name);
  await writeSnapshot(tester, name);
  expect(tester.takeException(), isNull);
}

void main() {
  setUpAll(loadRealFonts);

  for (final (label, size) in [('desktop', _desktop), ('phone', _phone)]) {
    testWidgets('admin join gate section at $label', (tester) async {
      await _pump(
        tester,
        size,
        const Scaffold(
          body: SingleChildScrollView(
            padding: EdgeInsets.all(AppSpacing.s16),
            child: JoinGateSection(),
          ),
        ),
      );
      await _finish(tester, 'join-gate-admin-$label');
    });

    testWidgets('waiting member banner and rules at $label', (tester) async {
      await _pump(
        tester,
        size,
        const Scaffold(
          body: RulesGateBannerHost(
            child: Center(child: Text('the shell, with #rules open')),
          ),
        ),
      );
      await _finish(tester, 'join-gate-banner-$label');
      await tester.tap(find.text('Read the rules'));
      await tester.pumpAndSettle();
      await _finish(tester, 'join-gate-rules-$label');
    });
  }
}
