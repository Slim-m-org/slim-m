// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A panel redraw that fails any way at all leaves the scene on screen instead
/// of escaping as an unhandled async error.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/features/modules/providers/module_panels.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

import 'module_panel_fixture.dart';

void main() {
  test('a redraw the server answers oddly keeps the scene', () async {
    var calls = 0;
    final container = ProviderContainer(
      overrides: [
        apiProvider.overrideWith((ref) {
          final client = testApi((request) async {
            calls++;
            final body = calls == 1
                ? {
                    'ok': true,
                    'output': jsonEncode({
                      r'$slim': 'scene/1',
                      'width': 4,
                      'height': 3,
                      'ops': <Object>[],
                      'refresh_ms': 1000,
                    }),
                  }
                : {'ok': true, 'output': 5};
            return http.Response(
              jsonEncode(body),
              200,
              headers: {'content-type': 'application/json'},
            );
          });
          ref.onDispose(client.close);
          return client;
        }),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(modulePanelRunsProvider, (_, _) {});
    addTearDown(sub.close);
    final runs = container.read(modulePanelRunsProvider.notifier);
    await runs.open(boardPanel);
    final held = sub.read()[boardPanel.key];
    expect(held?.refreshEvery, isNotNull);

    await runs.refresh(boardPanel);

    expect(calls, 2);
    expect(sub.read()[boardPanel.key], same(held));
  });
}
