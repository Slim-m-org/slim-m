// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Health card on a module's Dock screen: why the breaker turned it off,
/// with a way back on, and its failure streak and dropped events.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/screens/admin/dock_health_card.dart';
import 'package:slimm_app/src/features/settings/screens/admin/dock_module_view.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../dock_manifest_fixture.dart';

api.InstalledDockModule _module({
  bool enabled = true,
  int failures = 0,
  String? reason,
  int dropped = 0,
  int queued = 0,
}) => api.InstalledDockModule.fromJson({
  'id': 'xp',
  'name': 'xp',
  'version': '1.0.0',
  'artifact_sha256': 'a' * 64,
  'approved_capabilities': <String>[],
  'extension_points': <Object>[],
  'enabled': enabled,
  'installed_at': 1,
  'consecutive_failures': failures,
  'disabled_reason': ?reason,
  'events_dropped': dropped,
  'queue_depth': queued,
});

Future<void> _pump(
  WidgetTester tester,
  api.InstalledDockModule installed, {
  VoidCallback? onTurnOn,
}) => tester.pumpWidget(
  MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(
      body: DockHealthCard(installed: installed, onTurnOn: onTurnOn ?? () {}),
    ),
  ),
);

void main() {
  test('a healthy module has no news', () {
    expect(dockHasHealthNews(_module()), isFalse);
    expect(dockHasHealthNews(null), isFalse);
  });

  test('events waiting count as news', () {
    expect(dockHasHealthNews(_module(queued: 1)), isTrue);
  });

  testWidgets('a module with events waiting says how many', (tester) async {
    await _pump(tester, _module(queued: 12));
    expect(find.text('12 events are waiting for it.'), findsOneWidget);
    await _pump(tester, _module(queued: 1));
    await tester.pump();
    expect(find.text('1 event is waiting for it.'), findsOneWidget);
  });

  testWidgets('a module the breaker turned off says why and can be turned on', (
    tester,
  ) async {
    var turnedOn = 0;
    await _pump(
      tester,
      _module(enabled: false, failures: 5, reason: 'Failed 5 runs in a row.'),
      onTurnOn: () => turnedOn++,
    );
    expect(find.text('Turned off'), findsOneWidget);
    expect(find.text('Failed 5 runs in a row.'), findsOneWidget);
    expect(find.text('5 runs failed in a row.'), findsOneWidget);
    await tester.tap(find.text('Turn on'));
    expect(turnedOn, 1);
  });

  testWidgets('a running module reports its streak and dropped events', (
    tester,
  ) async {
    final installed = _module(failures: 2, dropped: 7);
    expect(dockHasHealthNews(installed), isTrue);
    await _pump(tester, installed);
    expect(find.text('Health'), findsOneWidget);
    expect(find.text('2 runs failed in a row.'), findsOneWidget);
    expect(
      find.text('7 events were dropped because it fell behind.'),
      findsOneWidget,
    );
    expect(find.text('Turn on'), findsNothing);
  });

  testWidgets('the module page shows the card and turning on enables it', (
    tester,
  ) async {
    final enabled = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: SingleChildScrollView(
            child: DockManifestView(
              manifest: api.DockManifest.fromJson(
                dockManifestJson('xp', '1.0.0'),
              ),
              installed: _module(enabled: false, reason: 'Too many failures.'),
              busy: false,
              error: null,
              onErrorDismiss: () {},
              onInstall: () {},
              onSetEnabled: enabled.add,
              onUninstall: () {},
              onChooseAccess: () {},
              approvedHostCapabilities: const {},
              onToggleHostCapability: (_, _) {},
            ),
          ),
        ),
      ),
    );
    expect(find.text('Too many failures.'), findsOneWidget);
    await tester.ensureVisible(find.text('Turn on'));
    await tester.tap(find.text('Turn on'));
    expect(enabled, [true]);
  });
}
