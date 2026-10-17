// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Capture helper, asserts nothing: word-guess and minesweeper in a card at a desktop and a
/// phone width, so the framing can be looked at. PNGs are written only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/modules/widgets/module_scene.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_view.dart';
import 'package:slimm_design_system/design_system.dart';

import 'module_scene_fixtures.dart';
import 'ui_snapshot_support.dart';

Future<void> _shot(WidgetTester tester, String name, double width) async {
  tester.view.physicalSize = Size(width + 32, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final tokens = AppTokens.dark;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark, tokens),
      home: Scaffold(
        body: RepaintBoundary(
          key: snapshotBoundary,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: ModuleSceneView(
                  initial: parseModuleScene(
                    jsonEncode(shippedScenes[name.split('-@').first]),
                  )!,
                  onExpand: () {},
                  runCommand: (_) async =>
                      const api.RunModuleCommandResult(ok: true, output: ''),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await writeSnapshot(
    tester,
    'module-scene-crop-${name.replaceAll('-@', '-')}',
  );
}

void main() {
  setUpAll(loadRealFonts);

  for (final (label, width) in const [('desktop', 760.0), ('phone', 358.0)]) {
    for (final game in const ['word-guess', 'minesweeper']) {
      testWidgets('$game at $label width', (tester) async {
        await _shot(tester, '$game-@$label', width);
      });
    }
  }
}
