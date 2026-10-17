// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The scene, mounting and drag helpers the module-scene widget tests share.
///
/// Split out of module_scene_drag_test.dart when adding a play-path
/// regression pushed it past the line budget; the drag tests and the play
/// tests are different concerns that happened to want the same 4x4 board.
library;

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/modules/widgets/module_scene.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_view.dart';
import 'package:slimm_design_system/design_system.dart';

/// A 4x4 board whose cells answer `toggle`, the shape game-of-life sends.
///
/// [tapBatch] mirrors the module's own `tap_batch`: game-of-life 0.3.0 reads a
/// `;`-separated list of cells, 0.2.0 does not and answers "bad cell" to one.
String sceneJson(int gen, {bool live = true, bool tapBatch = false}) =>
    jsonEncode({
      r'$slim': 'scene/1',
      'width': 4,
      'height': 4,
      'ops': [
        {
          'op': 'cells',
          'cols': 4,
          'rows': 4,
          'data': '................',
          'tap': 'toggle',
          'tap_batch': tapBatch,
        },
      ],
      'state': 'g$gen',
      'controls': ['play', 'step'],
      'live': live,
    });

/// Mounts the view at a known size and records every action it sends.
Future<List<String>> actionsFrom(
  WidgetTester tester,
  Future<void> Function(WidgetTester tester, Offset topLeft) drive, {
  Duration latency = Duration.zero,
  bool tapBatch = false,
}) async {
  final actions = <String>[];
  var gen = 0;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            child: ModuleSceneView(
              initial: parseModuleScene(sceneJson(0, tapBatch: tapBatch))!,
              runCommand: (input) async {
                actions.add(jsonDecode(input)['action'] as String);
                if (latency > Duration.zero) {
                  await Future<void>.delayed(latency);
                }
                return api.RunModuleCommandResult(
                  ok: true,
                  output: sceneJson(++gen, tapBatch: tapBatch),
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final board = find.descendant(
    of: find.byType(ModuleSceneView),
    matching: find.byType(CustomPaint),
  );
  await drive(tester, tester.getTopLeft(board.last));
  await tester.pumpAndSettle();
  return actions;
}

/// Moves in 20px steps from [from] to [to]. A single long `moveTo` clears the
/// drag threshold in one jump, so `onPanStart` fires wherever it lands rather
/// than in the cell the finger actually started in - which no real drag does.
Future<void> dragThrough(
  WidgetTester tester,
  Offset from,
  List<Offset> waypoints,
) async {
  final gesture = await tester.startGesture(from);
  var current = from;
  for (final target in waypoints) {
    final steps = ((target - current).distance / 20).ceil().clamp(1, 200);
    for (var i = 1; i <= steps; i++) {
      current = Offset.lerp(current, target, i / steps)!;
      await gesture.moveTo(current);
      await tester.pump();
    }
    current = target;
  }
  await gesture.up();
}
