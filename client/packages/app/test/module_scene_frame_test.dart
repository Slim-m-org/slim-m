// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How big a scene is drawn, which two opposite complaints have shaped. A
/// fixed 420px cap left a small square adrift in a desktop card twice its
/// width; a share of the window height then made a three-by-three board 650px
/// tall on a 1080p desktop. The board is now bounded per cell, so a small grid
/// stays a board while a big one is still limited by the window.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/modules/widgets/module_scene.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_frame.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_view.dart';
import 'package:slimm_design_system/design_system.dart';

String _scene({int cols = 3, int rows = 3}) => jsonEncode({
  r'$slim': 'scene/1',
  'width': cols,
  'height': rows,
  'ops': [
    {
      'op': 'cells',
      'cols': cols,
      'rows': rows,
      'data': '0' * (cols * rows),
      'palette': ['sunken', 'accent'],
    },
  ],
  'controls': ['play', 'step', 'random', 'clear'],
});

Future<api.RunModuleCommandResult> _run(String input) async =>
    const api.RunModuleCommandResult(ok: true, output: 'x');

Future<void> _pump(WidgetTester tester, Size window, {String? scene}) async {
  tester.view.physicalSize = window;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: Scaffold(
        body: ModuleSceneView(
          initial: parseModuleScene(scene ?? _scene())!,
          runCommand: _run,
        ),
      ),
    ),
  );
}

/// The bordered box, not the paint inside it: the hairline sits inside the
/// box and would otherwise cost the measurement two pixels.
Size _board(WidgetTester tester) => tester.getSize(
  find.descendant(
    of: find.byType(ModuleSceneFrame),
    matching: find.byType(Container),
  ),
);

void main() {
  testWidgets('a small board is past the old 420px cap but not huge', (
    tester,
  ) async {
    await _pump(tester, const Size(1200, 900));
    final board = _board(tester);
    expect(
      board.width,
      lessThanOrEqualTo(ModuleSceneFrame.maxWideInlineEdge),
      reason: 'a compact inline widget, not a billboard',
    );
    expect(
      board.width,
      3 * ModuleSceneFrame.maxCellSize,
      reason: 'the per-cell bound is the tighter one for three rows',
    );
    expect(
      board.width,
      lessThan(900 * ModuleSceneFrame.viewportShare),
      reason: 'a tic-tac-toe grid does not want its share of the window',
    );
    expect(board.height, board.width);
  });

  testWidgets('a big grid is bounded inline as well', (tester) async {
    await _pump(
      tester,
      const Size(1200, 900),
      scene: _scene(cols: 40, rows: 40),
    );
    final board = _board(tester);
    expect(
      board.height,
      closeTo(ModuleSceneFrame.maxWideInlineEdge, 1.5),
      reason: 'a big grid is bounded inline too; full screen is where it grows',
    );
  });

  testWidgets('on a phone the board is the full width', (tester) async {
    await _pump(tester, const Size(340, 800));
    expect(_board(tester).width, 340);
  });

  testWidgets('a wide scene follows its own aspect ratio', (tester) async {
    await _pump(tester, const Size(1200, 900), scene: _scene(cols: 6, rows: 3));
    final board = _board(tester);
    expect(board.width / board.height, closeTo(2, 0.01));
    // Within the hairline: the border rounds the inner box by a pixel.
    expect(board.height, closeTo(3 * ModuleSceneFrame.maxCellSize, 1.5));
  });

  testWidgets('a short window keeps a usable board', (tester) async {
    await _pump(tester, const Size(1200, 300));
    expect(_board(tester).height, ModuleSceneFrame.minHeight);
  });

  testWidgets('every control says what it does on hover', (tester) async {
    await _pump(tester, const Size(1200, 900));
    for (final message in ['Play', 'Step forward', 'Randomise', 'Clear']) {
      expect(find.byTooltip(message), findsOneWidget, reason: message);
    }
  });
}
