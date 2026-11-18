// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The grid's keyboard cursor shows only once the keyboard is in use.
///
/// A click gives the grid focus so the arrows work next, and the cursor's
/// ring was drawn on that focus alone: Minesweeper's top-left cell looked
/// tabbed to after a game played entirely with the mouse. Focus Flutter
/// hands back on its own (a closed menu, a window regaining focus) follows the
/// last input too, not how focus arrived.
library;

import 'dart:async';
import 'dart:convert';

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

Future<void> _pump(WidgetTester tester, {String? scene}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark, _tokens),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            child: ModuleSceneView(
              initial: parseModuleScene(scene ?? sceneJson(0))!,
              runCommand: (input) async => api.RunModuleCommandResult(
                ok: true,
                output: scene ?? sceneJson(1),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// Past the dialog route's open or close transition.
Future<void> _pastTransition(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
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

  testWidgets('focus a closed dialog hands back after a click stays quiet', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(_grid.last, kind: PointerDeviceKind.mouse);
    await tester.pump();

    final closed = showDialog<void>(
      context: tester.element(_grid.last),
      builder: (_) => const Text('menu'),
    );
    await _pastTransition(tester);
    Navigator.of(tester.element(find.text('menu'))).pop();
    await closed;
    await _pastTransition(tester);

    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Module scene grid');
    expect(_ring, findsNothing);
  }, variant: desktop);

  testWidgets('picking from the scene dropdown with the mouse stays quiet', (
    tester,
  ) async {
    final withSelect = jsonDecode(sceneJson(0)) as Map<String, Object?>
      ..['controls'] = [
        {
          'label': 'difficulty',
          'value': 'expert',
          'options': ['beginner', 'expert'],
        },
      ];
    await _pump(tester, scene: jsonEncode(withSelect));
    await tester.tap(_grid.last, kind: PointerDeviceKind.mouse);
    await tester.pump();

    await tester.tap(find.text('expert'), kind: PointerDeviceKind.mouse);
    await _pastTransition(tester);
    await tester.tap(find.text('beginner').last, kind: PointerDeviceKind.mouse);
    await _pastTransition(tester);

    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Module scene grid');
    expect(_ring, findsNothing);
  }, variant: desktop);

  testWidgets('a dialog closed by key hands back focus with the ring', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(_grid.last, kind: PointerDeviceKind.mouse);
    await tester.pump();

    unawaited(
      showDialog<void>(
        context: tester.element(_grid.last),
        builder: (_) => const Text('menu'),
      ),
    );
    await _pastTransition(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _pastTransition(tester);

    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Module scene grid');
    expect(_ring, findsOneWidget);
  }, variant: desktop);

  testWidgets('alt-tab away and back after a click stays quiet', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(_grid.last, kind: PointerDeviceKind.mouse);
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Module scene grid');
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
