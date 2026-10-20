// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Space-wide link preview switch on the performance pane: it shows the
/// served value and patches only that field.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/screens/admin/performance_screen.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_toggle_row.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

const _tokens = api.TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

http.Response _json(Map<String, dynamic> body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  testWidgets('turning previews off patches only that field', (tester) async {
    var enabled = true;
    final patches = <Map<String, dynamic>>[];
    final client = MockClient((request) async {
      switch (request.url.path) {
        case '/space/link-previews':
          if (request.method == 'PATCH') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            patches.add(body);
            enabled = body['enabled'] as bool;
          }
          return _json({'enabled': enabled});
        case '/space/retention':
          return _json({'retention_days': 0});
        case '/space/canvas-cap':
          return _json({'object_cap': 20000});
      }
      return _json({'enabled': false});
    });
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        apiProvider.overrideWith((ref) {
          final built = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: client,
          );
          ref.onDispose(built.close);
          return built;
        }),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: const Scaffold(body: PerformanceScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final toggle = find.byWidgetPredicate(
      (w) => w is SettingsToggleRow && w.label == 'Preview links',
    );
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<SettingsToggleRow>(toggle).value, isTrue);

    tester.widget<SettingsToggleRow>(toggle).onChanged!(false);
    await tester.pumpAndSettle();

    expect(patches, [
      {'enabled': false},
    ]);
    expect(tester.widget<SettingsToggleRow>(toggle).value, isFalse);
  });
}
