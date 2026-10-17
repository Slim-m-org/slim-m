// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Dock's "What it adds" card names a module's entry points in plain
/// language, from whatever its manifest declares - naming nothing
/// module-specific, and still listing a kind it does not recognise.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/screens/admin/dock_what_it_adds.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _pump(
  WidgetTester tester,
  List<api.DockExtensionPoint> eps,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(body: DockWhatItAddsCard(extensionPoints: eps)),
    ),
  );
}

void main() {
  testWidgets('names each surfaced kind in plain language', (tester) async {
    await _pump(tester, const [
      api.DockExtensionPoint(kind: 'command', name: 'roll', permission: 'roll'),
      api.DockExtensionPoint(
        kind: 'slash-command',
        name: 'roll',
        command: 'roll',
        permission: 'roll',
      ),
      api.DockExtensionPoint(
        kind: 'app',
        name: 'Game of Life',
        command: 'life',
        permission: 'play',
      ),
      api.DockExtensionPoint(
        kind: 'code-block-runner',
        name: 'Play',
        command: 'life',
        language: 'life',
        permission: 'play',
      ),
    ]);

    expect(find.text('/roll'), findsOneWidget);
    expect(find.text('Game of Life'), findsOneWidget);
    expect(find.text('Run life code blocks'), findsOneWidget);
    // The bare `command` is plumbing, not an entry point, so it is not listed.
    expect(find.text('roll'), findsNothing);
  });

  testWidgets('a runner naming no language says it runs nothing yet', (
    tester,
  ) async {
    await _pump(tester, const [
      api.DockExtensionPoint(
        kind: 'code-block-runner',
        name: 'Run',
        command: 'run',
        permission: 'run',
      ),
    ]);
    expect(find.text('Run code blocks'), findsOneWidget);
    expect(
      find.textContaining('has not said which language it runs'),
      findsOneWidget,
    );
  });

  testWidgets('an unrecognised kind still lists generically', (tester) async {
    await _pump(tester, const [
      api.DockExtensionPoint(kind: 'theme', name: 'Midnight'),
    ]);
    expect(find.text('Midnight'), findsOneWidget);
  });

  testWidgets('bare commands only renders nothing', (tester) async {
    await _pump(tester, const [
      api.DockExtensionPoint(kind: 'command', name: 'run', permission: 'run'),
    ]);
    expect(find.byType(Text), findsNothing);
  });
}
