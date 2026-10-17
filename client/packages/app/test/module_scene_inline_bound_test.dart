// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The inline board is bounded on every width, for scenes of any coordinate
/// space. A tic-tac-toe board drawn from rects declares a height in arbitrary
/// units, so the per-cell bound never applied and it took 60% of the window:
/// 650px on a 1818x1071 desktop. The scene's aspect ratio is bounded too.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/module_scene.dart';
import 'package:slimm_app/src/widgets/module_scene_frame.dart';
import 'package:slimm_app/src/widgets/module_scene_view.dart';
import 'package:slimm_design_system/design_system.dart';

String _rectScene(double w, double h) => jsonEncode({
  r'$slim': 'scene/1',
  'width': w,
  'height': h,
  'ops': [
    {'op': 'rect', 'x': 0, 'y': 0, 'w': w, 'h': h, 'fill': 'sunken'},
  ],
  'controls': ['clear'],
});

Future<Size> _boardAt(WidgetTester tester, Size window, String scene) async {
  tester.view.physicalSize = window;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: Scaffold(
        body: ModuleSceneView(
          initial: parseModuleScene(scene)!,
          runCommand: (_) async => throw StateError('unused'),
        ),
      ),
    ),
  );
  return tester.getSize(
    find.descendant(
      of: find.byType(ModuleSceneFrame),
      matching: find.byType(Container),
    ),
  );
}

void main() {
  const windows = {
    'phone 390': Size(390, 844),
    'tablet 800': Size(800, 1000),
    'laptop 1280': Size(1280, 800),
    'desktop 1818': Size(1818, 1071),
  };

  for (final entry in windows.entries) {
    testWidgets('a 300 unit square board is bounded on ${entry.key}', (
      tester,
    ) async {
      final board = await _boardAt(tester, entry.value, _rectScene(300, 300));
      final edge = math.min(
        ModuleSceneFrame.inlineEdge(entry.value.width),
        math.max(
          ModuleSceneFrame.minHeight,
          entry.value.height * ModuleSceneFrame.viewportShare,
        ),
      );
      expect(board.width, lessThanOrEqualTo(edge));
      expect(board.height, lessThanOrEqualTo(edge));
      expect(board.width, board.height);
      expect(board.width, entry.value.width < edge ? entry.value.width : edge);
    });
  }

  testWidgets('a very wide scene is clamped, not a sliver', (tester) async {
    final scene = parseModuleScene(_rectScene(1000, 1))!;
    expect(scene.width / scene.height, ModuleScene.maxAspect);
    final board = await _boardAt(
      tester,
      const Size(390, 844),
      _rectScene(1000, 1),
    );
    expect(board.height, greaterThan(80));
  });

  testWidgets('a very tall scene is clamped, not a sliver', (tester) async {
    final scene = parseModuleScene(_rectScene(1, 1000))!;
    expect(scene.height / scene.width, ModuleScene.maxAspect);
    final board = await _boardAt(
      tester,
      const Size(1280, 800),
      _rectScene(1, 1000),
    );
    expect(board.width, greaterThan(80));
  });

  test('a scene inside the ceiling keeps its own size', () {
    final scene = parseModuleScene(_rectScene(400, 100))!;
    expect((scene.width, scene.height), (400, 100));
  });
}
