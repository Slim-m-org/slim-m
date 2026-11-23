// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The connector consent sheet names a verified connector in words beside its badge.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/screens/admin/dock_connector_consent.dart';
import 'package:slimm_design_system/design_system.dart';

final _manifest = api.DockManifest.fromJson({
  'id': 'bridge',
  'name': 'Bridge',
  'version': '1.0.0',
  'summary': 'A bridge.',
  'artifact': {'kind': 'connector', 'path': 'x', 'sha256': 'a' * 64},
  'runtime': {'backend': 'connector', 'limits': <String, dynamic>{}},
  'permissions': <Object>[],
  'capabilities': <String>[],
  'extension_points': <Object>[],
  'provider': 'connector',
  'connector': {'permissions': 2},
});

void main() {
  testWidgets('a verified connector says so in text on the badge line', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDockConnectorConsent(
              context,
              manifest: _manifest,
              verified: true,
              isUpdate: false,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    final badge = tester.getRect(find.byIcon(AppIcons.verified));
    final words = tester.getRect(find.textContaining('Verified:'));
    expect(words.left, greaterThan(badge.right));
    expect((words.center.dy - badge.center.dy).abs(), lessThan(8));
  });
}
