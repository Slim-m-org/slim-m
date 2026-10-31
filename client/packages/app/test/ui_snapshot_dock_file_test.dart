// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Modules list with one module installed from a file: its card, the
/// install action, and the unverified label, at phone and desktop in both themes.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart'
    show apiProvider, sessionProvider;
import 'package:slimm_test_support/slimm_test_support.dart';

import 'ui_snapshot_support.dart';

final _fromFile = {
  'id': 'focus-timer',
  'name': 'Focus Timer',
  'version': '0.2.0',
  'artifact_sha256': 'b' * 64,
  'approved_capabilities': <String>[],
  'extension_points': <Object>[],
  'enabled': false,
  'installed_at': 1000,
  'source_repo': api.kFileDockRepo,
};

api.SlimmApi _dock(Ref ref) => testApi((request) async {
  final answer = switch (request.url.path) {
    '/space/dock/sources' => [
      {'id': 'official', 'repo': 'Slim-m-org/slim-addons', 'official': true},
    ],
    '/space/dock/modules' => <Object>[],
    '/space/dock/installed' => [_fromFile],
    _ => null,
  };
  if (answer == null) return fixtureResponse(request);
  return http.Response(
    jsonEncode(answer),
    200,
    headers: {'content-type': 'application/json'},
  );
}, session: ref.watch(sessionProvider));

void main() {
  setUpAll(loadRealFonts);

  for (final viewport in phoneAndDesktop) {
    testWidgets('dock-file at $viewport shows the file card', (tester) async {
      await renderSurface(
        tester,
        '/settings/dock',
        viewport,
        darkAndLight,
        'dock-file-$viewport-$darkAndLight',
        overrides: [apiProvider.overrideWith(_dock)],
        settleNestedResolve: true,
        afterSettle: (tester) async {
          expect(find.text('Module files'), findsOneWidget);
          expect(find.text('Focus Timer'), findsOneWidget);
          expect(find.text('Install from a file'), findsOneWidget);
          final button = tester.getRect(find.text('Install from a file'));
          final width = tester.view.physicalSize.width;
          expect(button.right, lessThanOrEqualTo(width));
          expect(button.left, greaterThanOrEqualTo(0));
        },
      );
    });
  }
}
