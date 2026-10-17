// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Frames of an animated scene at a phone and a desktop width, so the motion
/// can be looked at: a playhead crossing a grid and a progress bar filling.
///
/// PNGs are written only under SLIMM_UI_SNAPSHOTS=1, like the rest of the
/// matrix; unset, this still asserts nothing overflows.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/modules/widgets/module_scene.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_view.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../ui_snapshot_support.dart';

const _cells =
    '0010000000100000'
    '0000100000001000'
    '1000000010000000'
    '0000001000000010'
    '0100000001000000'
    '0000010000000100'
    '0001000000010000'
    '0000000100000001';

final _scene = parseModuleScene('''
{
  "\$slim": "scene/1",
  "width": 160, "height": 100,
  "ops": [
    {"op": "text", "x": 4, "y": 4, "s": "playing", "size": 8, "fill": "muted"},
    {"op": "cells", "cols": 16, "rows": 8, "data": "$_cells",
     "palette": ["sunken", "accent"], "gap": 0.5,
     "x": 4, "y": 14, "w": 152, "h": 64},
    {"op": "rect", "x": 4, "y": 12, "w": 3, "h": 68, "fill": "danger", "r": 1,
     "sweep": {"dx": 149, "secs": 2}},
    {"op": "rect", "x": 4, "y": 88, "w": 0, "h": 6, "fill": "accent", "r": 3,
     "sweep": {"dw": 152, "secs": 2}}
  ]
}
''')!;

Future<void> _frames(WidgetTester tester, String label, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: Scaffold(
        body: RepaintBoundary(
          key: snapshotBoundary,
          child: Center(
            child: SizedBox(
              width: size.width - 32,
              child: ModuleSceneView(
                initial: _scene,
                runCommand: (_) async =>
                    api.RunModuleCommandResult(ok: true, output: ''),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  for (final (index, step) in const [0, 1000, 1000].indexed) {
    await tester.pump(Duration(milliseconds: step));
    await writeSnapshot(tester, 'module-scene-sweep-$label-$index');
  }
  await tester.pump(const Duration(seconds: 2));
  await writeSnapshot(tester, 'module-scene-sweep-$label-end');
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets('phone width', (tester) async {
    await _frames(tester, 'phone', const Size(390, 700));
  });

  testWidgets('desktop width', (tester) async {
    await _frames(tester, 'desktop', const Size(1100, 700));
  });
}
