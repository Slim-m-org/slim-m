// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The grid's keyboard cursor shows only once the keyboard is in use.
///
/// A click gives the grid focus so the arrows work next, and the cursor's
/// ring was drawn on that focus alone: Minesweeper's top-left cell looked
/// tabbed to after a game played entirely with the mouse.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/modules/widgets/module_scene.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_view.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/module_scene_fixtures.dart';

const _tokens = AppTokens.dark;

final _ring = find.byWidgetPredicate(
  (w) =>
      w is DecoratedBox &&
      w.decoration is BoxDecoration &&
      (w.decoration as BoxDecoration).border ==
          Border.all(color: _tokens.focusRing, width: 2),
);

final _grid = find.bySemanticsLabel(RegExp('^Scene grid'));

Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark, _tokens),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            child: ModuleSceneView(
              initial: parseModuleScene(sceneJson(0))!,
              runCommand: (input) async =>
                  api.RunModuleCommandResult(ok: true, output: sceneJson(1)),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  final desktop = TargetPlatformVariant.only(TargetPlatform.linux);

  testWidgets('a click on a cell draws no keyboard ring', (tester) async {
    await _pump(tester);

    await tester.tap(_grid.last, kind: PointerDeviceKind.mouse);
    await tester.pump();

    expect(_ring, findsNothing);
  }, variant: desktop);

  testWidgets('an arrow key after the click shows the ring', (tester) async {
    await _pump(tester);
    await tester.tap(_grid.last, kind: PointerDeviceKind.mouse);
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();

    expect(_ring, findsOneWidget);
  }, variant: desktop);

  testWidgets('a click after the keyboard hides the ring again', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(_grid.last, kind: PointerDeviceKind.mouse);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(_ring, findsOneWidget);

    await tester.tap(_grid.last, kind: PointerDeviceKind.mouse);
    await tester.pump();

    expect(_ring, findsNothing);
  }, variant: desktop);

  testWidgets('focus that arrives by Tab shows the ring', (tester) async {
    await _pump(tester);

    for (var i = 0; i < 6; i++) {
      final focused = FocusManager.instance.primaryFocus?.debugLabel;
      if (focused == 'Module scene grid') break;
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }

    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Module scene grid');
    expect(_ring, findsOneWidget);
  }, variant: desktop);
}
