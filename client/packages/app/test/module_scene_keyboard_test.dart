// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A module scene's grid was pointer/touch only: `docs/BACKLOG.md`'s
/// keyboard-drivable bar, written for the Voice Canvas, applies here too.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/modules/widgets/module_scene.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_view.dart';
import 'package:slimm_design_system/design_system.dart';

import 'support/module_scene_fixtures.dart';

void main() {
  testWidgets(
    'arrow keys move a focus across the grid, enter activates the cell there',
    (tester) async {
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
                  initial: parseModuleScene(sceneJson(0))!,
                  runCommand: (input) async {
                    actions.add(jsonDecode(input)['action'] as String);
                    return api.RunModuleCommandResult(
                      ok: true,
                      output: sceneJson(++gen),
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
      // Down then cancel: grabs focus via the pointer listener, sends no tap.
      final gesture = await tester.startGesture(tester.getCenter(board.last));
      await gesture.cancel();
      await tester.pump();
      expect(actions, isEmpty);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(actions, ['toggle:1,1']);
    },
  );

  testWidgets('a keyboard move is clamped at the grid edge', (tester) async {
    final actions = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              child: ModuleSceneView(
                initial: parseModuleScene(sceneJson(0))!,
                runCommand: (input) async {
                  actions.add(jsonDecode(input)['action'] as String);
                  return api.RunModuleCommandResult(
                    ok: true,
                    output: sceneJson(1),
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
    final gesture = await tester.startGesture(tester.getCenter(board.last));
    await gesture.cancel();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(actions, ['toggle:0,0']);
  });
}
