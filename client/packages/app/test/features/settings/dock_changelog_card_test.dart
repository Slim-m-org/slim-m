// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The "What's new" card: the newest entry before install, nothing when the
/// module publishes no changelog.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/screens/admin/dock_changelog_card.dart';
import 'package:slimm_design_system/design_system.dart';

api.DockManifest _manifest(List<Map<String, Object>> changelog) =>
    api.DockManifest.fromJson({
      'id': 'dice',
      'name': 'Dice',
      'version': '0.1.3',
      'summary': 's',
      'artifact': {'kind': 'wasm', 'path': 'p', 'sha256': 'a'},
      'runtime': {
        'backend': 'wasm',
        'limits': {'memory_mb': 64, 'wall_ms': 2000, 'fuel': 1},
      },
      'permissions': <Object>[],
      'capabilities': <Object>[],
      'extension_points': <Object>[],
      'changelog': changelog,
    });

Future<void> _pump(
  WidgetTester tester,
  api.DockManifest m,
  String? installed,
) => tester.pumpWidget(
  MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: Scaffold(
      body: DockChangelogCard(manifest: m, installedVersion: installed),
    ),
  ),
);

void main() {
  final notes = _manifest([
    {
      'version': '0.1.3',
      'changes': ['Newest change'],
    },
    {
      'version': '0.1.2',
      'changes': ['Older change'],
    },
  ]);

  testWidgets('not installed: only the newest entry', (tester) async {
    await _pump(tester, notes, null);
    expect(find.text("What's new"), findsOneWidget);
    expect(find.text('v0.1.3'), findsOneWidget);
    expect(find.text('Newest change'), findsOneWidget);
    expect(find.text('Older change'), findsNothing);
  });

  testWidgets('installed older: every newer entry', (tester) async {
    await _pump(tester, notes, '0.1.1');
    expect(find.text('Newest change'), findsOneWidget);
    expect(find.text('Older change'), findsOneWidget);
  });

  testWidgets('an empty changelog renders nothing', (tester) async {
    await _pump(tester, _manifest([]), null);
    expect(find.text("What's new"), findsNothing);
  });

  testWidgets('caps at five entries and counts the rest', (tester) async {
    final many = _manifest([
      for (var i = 9; i >= 1; i--)
        {
          'version': '0.$i.0',
          'changes': ['change $i'],
        },
    ]);
    await _pump(tester, many, '0.0.1');
    expect(find.text('v0.9.0'), findsOneWidget);
    expect(find.text('v0.5.0'), findsOneWidget);
    expect(find.text('v0.4.0'), findsNothing);
    expect(find.text('and 4 earlier versions'), findsOneWidget);
  });
}
