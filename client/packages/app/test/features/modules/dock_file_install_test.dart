// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Installing from a module file: the file goes to the server for a preview,
/// the consent sheet lists what it asks for, and a refused file is said so.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/screens/admin/dock_file_install.dart';
import 'package:slimm_app/src/providers/providers.dart'
    show apiProvider, sessionProvider;
import 'package:slimm_test_support/slimm_test_support.dart';

import '../../ui_snapshot_support.dart';

const Map<String, Object> _manifest = {
  'id': 'focus-timer',
  'name': 'Focus Timer',
  'version': '0.2.0',
  'summary': 'A timer.',
  'artifact': {'kind': 'wasm', 'path': 'm.wasm', 'sha256': 'b'},
  'runtime': {'backend': 'wasm', 'limits': <String, Object>{}},
  'permissions': <Object>[],
  'capabilities': ['schedule'],
  'extension_points': <Object>[],
  'schedules': <Object>[],
  'changelog': <Object>[],
  'review_digest': 'digest',
};

api.SlimmApi Function(Ref) _dock(List<String> seen, {required bool refuse}) =>
    (ref) => testApi((request) async {
      seen.add('${request.method} ${request.url.path}');
      Object? answer;
      var status = 200;
      switch (request.url.path) {
        case '/space/dock/sources':
          answer = [
            {'id': 'official', 'repo': 'o/r', 'official': true},
          ];
        case '/space/dock/modules' || '/space/dock/installed':
          answer = <Object>[];
        case '/space/dock/packages/preview':
          status = refuse ? 400 : 200;
          answer = refuse
              ? {'error': 'not a usable module package: it is too large'}
              : _manifest;
        default:
          return fixtureResponse(request);
      }
      return http.Response(
        jsonEncode(answer),
        status,
        headers: {'content-type': 'application/json'},
      );
    }, session: ref.watch(sessionProvider));

Future<DockPackagePick?> _pick() async => DockPackagePick(
  fileName: 'focus.json',
  bytes: utf8.encode(jsonEncode({r'$slim': 'module-package/1'})),
);

void main() {
  setUpAll(loadRealFonts);

  testWidgets('a chosen file is previewed and the consent sheet opens', (
    tester,
  ) async {
    final seen = <String>[];
    await renderSurface(
      tester,
      '/settings/dock',
      phoneAndDesktop.first,
      'dark',
      'dock-file-consent',
      overrides: [
        apiProvider.overrideWith(_dock(seen, refuse: false)),
        dockPackagePickerProvider.overrideWithValue(_pick),
      ],
      settleNestedResolve: true,
      afterSettle: (tester) async {
        await tester.tap(find.text('Install from a file'));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 400));
        expect(seen, contains('POST /space/dock/packages/preview'));
        expect(find.textContaining('Focus Timer'), findsWidgets);
        expect(seen.any((s) => s.contains('packages/install')), isFalse);
      },
    );
  });

  testWidgets('a refused file is named in a persistent error', (tester) async {
    final seen = <String>[];
    await renderSurface(
      tester,
      '/settings/dock',
      phoneAndDesktop.first,
      'dark',
      'dock-file-refused',
      overrides: [
        apiProvider.overrideWith(_dock(seen, refuse: true)),
        dockPackagePickerProvider.overrideWithValue(_pick),
      ],
      settleNestedResolve: true,
      afterSettle: (tester) async {
        await tester.tap(find.text('Install from a file'));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.textContaining('too large'), findsOneWidget);
      },
    );
  });
}
