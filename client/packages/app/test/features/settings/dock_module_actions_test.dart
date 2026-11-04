// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A module page's actions: Uninstall alone at the foot, Install or Update
/// pinned, and Export and stored data folded into Details.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/screens/admin/dock_module_actions.dart';
import 'package:slimm_app/src/features/settings/screens/admin/dock_module_details.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../dock_manifest_fixture.dart';

api.InstalledDockModule _installed({
  Map<String, dynamic>? storage,
  bool enabled = true,
  String version = '1.0.0',
}) => api.InstalledDockModule.fromJson({
  'id': 'xp',
  'name': 'xp',
  'version': version,
  'artifact_sha256': 'a' * 64,
  'approved_capabilities': <String>[],
  'extension_points': <Object>[],
  'enabled': enabled,
  'installed_at': 1,
  'storage': ?storage,
});

const _storage = {
  'entries': 12,
  'bytes': 3100,
  'max_entries': 256,
  'max_bytes': 65536,
};

/// Pumps the folded Details section and opens it.
Future<void> _pump(
  WidgetTester tester,
  api.InstalledDockModule? installed, {
  VoidCallback? onClear,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: SingleChildScrollView(
            child: DockModuleDetails(
              manifest: api.DockManifest.fromJson(
                dockManifestJson('xp', '1.0.0'),
              ),
              installed: installed,
              busy: false,
              showChangelog: true,
              onExport: () {},
              onClearStorage: onClear,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('dock-details-toggle')));
  await tester.pump();
}

void main() {
  testWidgets('Details holds Export once installed, not before', (
    tester,
  ) async {
    await _pump(tester, _installed());
    expect(find.text('Package file'), findsOneWidget);
    await _pump(tester, null);
    expect(find.text('Package file'), findsNothing);
  });

  testWidgets('Uninstall is one danger row', (tester) async {
    var removed = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: DockUninstallRow(busy: false, onUninstall: () => removed++),
        ),
      ),
    );
    expect(find.text('Remove from this space'), findsOneWidget);
    await tester.tap(find.widgetWithText(AppButton, 'Uninstall'));
    expect(removed, 1);
  });

  testWidgets('install shows only for a missing or outdated module', (
    tester,
  ) async {
    Future<void> pump(api.InstalledDockModule? installed) => tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: DockPrimaryAction(
            manifest: api.DockManifest.fromJson(
              dockManifestJson('xp', '2.0.0'),
            ),
            installed: installed,
            busy: false,
            onPressed: () {},
          ),
        ),
      ),
    );
    await pump(null);
    expect(find.text('Install v2.0.0'), findsOneWidget);
    await pump(_installed());
    expect(find.text('Update to v2.0.0'), findsOneWidget);
    await pump(_installed(version: '2.0.0'));
    expect(find.textContaining('v2.0.0'), findsNothing);
  });

  testWidgets('stored data shows usage and Clear data empties it', (
    tester,
  ) async {
    var cleared = 0;
    await _pump(
      tester,
      _installed(storage: _storage),
      onClear: () => cleared++,
    );
    expect(find.text('12 of 256 entries, 3.0 KB of 64 KB'), findsOneWidget);
    await tester.tap(find.widgetWithText(AppButton, 'Clear data'));
    expect(cleared, 1);
  });

  testWidgets(
    'Clear data is off when nothing is stored, absent without a clear '
    'callback',
    (tester) async {
      await _pump(
        tester,
        _installed(storage: {..._storage, 'entries': 0, 'bytes': 0}),
        onClear: () {},
      );
      final button = tester.widget<AppButton>(
        find.widgetWithText(AppButton, 'Clear data'),
      );
      expect(button.disabled, isTrue);

      await _pump(tester, _installed(storage: _storage));
      expect(find.text('Stored data'), findsNothing);
    },
  );
}
