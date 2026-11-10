// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Review captures of `overlay-module-scene-fullscreen`: a module's scene on a
/// screen of its own, drawn and after a step it could not run, at phone and
/// desktop width in both themes. PNGs are written only under
/// SLIMM_UI_SNAPSHOTS=1; otherwise each case asserts a clean layout.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/modules/widgets/module_scene.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_fullscreen.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_view.dart'
    show ModuleSceneRunner;
import 'package:slimm_design_system/design_system.dart';

import '../ui_snapshot_support.dart';
import 'ui_review_messages_support.dart';

const _surface = 'overlay-module-scene-fullscreen';

List<api.Message> _transcript() => [
  reviewMessage(1, 'user-nick', 'the board is live, have a look'),
];

String _sceneJson() {
  const cols = 20;
  const rows = 12;
  final cells = List<String>.filled(cols * rows, '0');
  for (final (r, c) in const [
    (1, 2),
    (2, 3),
    (3, 1),
    (3, 2),
    (3, 3),
    (6, 12),
    (6, 13),
    (6, 14),
    (8, 8),
    (8, 9),
    (9, 8),
    (9, 9),
  ]) {
    cells[r * cols + c] = '1';
  }
  return jsonEncode({
    r'$slim': 'scene/1',
    'width': cols,
    'height': rows,
    'ops': [
      {
        'op': 'cells',
        'cols': cols,
        'rows': rows,
        'data': cells.join(),
        'palette': ['sunken', 'accent'],
        'gap': 0.08,
        'tap': 'toggle',
      },
    ],
    'controls': ['play', 'step', 'random', 'clear'],
    'status': 'generation 41, 12 cells alive',
    'state': 'g41',
  });
}

Future<void> _openScene(
  ReviewScene scene, {
  required ModuleSceneRunner run,
}) async {
  unawaited(
    showModuleSceneFullscreen(
      scene.context,
      initial: parseModuleScene(_sceneJson())!,
      runCommand: run,
      title: 'game-of-life',
    ),
  );
  await scene.frames(3);
}

Future<api.RunModuleCommandResult> _ok(String input) async =>
    api.RunModuleCommandResult(ok: true, output: _sceneJson());

Future<api.RunModuleCommandResult> _crash(String input) async =>
    const api.RunModuleCommandResult(
      ok: false,
      error: 'game-of-life stopped: it ran out of memory on this board.',
    );

Future<void> _failStep(ReviewScene scene) async {
  await _openScene(scene, run: _crash);
  await scene.tester.tap(find.byIcon(AppIcons.forward));
  await scene.frames(3);
}

void main() {
  setUpAll(loadRealFonts);

  for (final viewport in reviewViewports.keys) {
    testWidgets('module scene at $viewport', (tester) async {
      await captureMessages(
        tester,
        surface: _surface,
        state: 'scene',
        viewport: viewport,
        messages: _transcript(),
        act: (scene) => _openScene(scene, run: _ok),
      );
    });

    testWidgets('module scene error at $viewport', (tester) async {
      await captureMessages(
        tester,
        surface: _surface,
        state: 'error',
        viewport: viewport,
        messages: _transcript(),
        act: _failStep,
      );
    });
  }
}
