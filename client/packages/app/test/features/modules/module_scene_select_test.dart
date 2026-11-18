// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A scene control that is one choice of several, shown as a dropdown.
///
/// Minesweeper offered its four board sizes as four buttons beside its
/// verbs, and the row wrapped into two lines of look-alike buttons.
library;

import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/modules/widgets/module_scene.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_view.dart';
import 'package:slimm_design_system/design_system.dart';

const _sizes = ['beginner', 'intermediate', 'expert', 'custom'];

ModuleScene _scene(List<Object?> controls) => parseModuleScene(
  jsonEncode({
    r'$slim': 'scene/1',
    'width': 100,
    'height': 100,
    'ops': [
      {'op': 'rect', 'x': 0, 'y': 0, 'w': 100, 'h': 100, 'fill': 'accent'},
    ],
    'controls': controls,
    'live': true,
  }),
)!;

Future<List<String>> _pump(
  WidgetTester tester,
  ModuleScene scene, {
  Alignment alignment = Alignment.topLeft,
}) async {
  final sent = <String>[];
  tester.view.physicalSize = const Size(1200, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: Scaffold(
        body: Align(
          alignment: alignment,
          child: SizedBox(
            width: 400,
            child: ModuleSceneView(
              initial: scene,
              runCommand: (input) async {
                sent.add(jsonDecode(input)['action'] as String);
                return const api.RunModuleCommandResult(ok: true, output: '');
              },
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return sent;
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  group('reading', () {
    test('an object with options is a dropdown, in its place in the row', () {
      final scene = _scene([
        'new game',
        {'label': 'board size', 'value': 'expert', 'options': _sizes},
        'scores',
      ]);
      expect(scene.controls, const [
        SceneButton('new game'),
        SceneSelect(label: 'board size', value: 'expert', options: _sizes),
        SceneButton('scores'),
      ]);
    });

    test('a value that is not an option shows no choice in force', () {
      final scene = _scene([
        {'label': 'board size', 'value': '20x12x30', 'options': _sizes},
      ]);
      expect((scene.controls.single as SceneSelect).value, isNull);
    });

    test('a dropdown with nothing to choose is skipped', () {
      final scene = _scene([
        {'label': 'empty', 'options': <String>[]},
        {
          'label': 'blank',
          'options': ['  ', 7],
        },
        {'label': 'no options'},
        42,
        'kept',
      ]);
      expect(scene.controls, const [SceneButton('kept')]);
    });

    test('the buttons a dropdown replaces are left out of the row', () {
      final scene = _scene([
        'new game',
        {
          'label': 'board size',
          'value': 'expert',
          'options': _sizes,
          'replaces': _sizes,
        },
        for (final size in _sizes) size,
        'leaderboard',
      ]);
      expect(scene.controls, [
        const SceneButton('new game'),
        const SceneSelect(
          label: 'board size',
          value: 'expert',
          options: _sizes,
        ),
        const SceneButton('leaderboard'),
      ]);
    });

    test('replacing counts against the cap only once, after the drop', () {
      final scene = _scene([
        {
          'options': ['a', 'b'],
          'replaces': [for (var i = 0; i < 20; i++) 'x$i'],
        },
        for (var i = 0; i < 20; i++) 'x$i',
        'kept',
      ]);
      expect(scene.controls.map((c) => c.runtimeType), [
        SceneSelect,
        SceneButton,
      ]);
      expect(scene.controls.last, const SceneButton('kept'));
    });

    test('a dropdown that cannot be shown replaces nothing', () {
      final scene = _scene([
        {
          'label': 'board size',
          'options': <String>[],
          'replaces': ['beginner'],
        },
        'beginner',
      ]);
      expect(scene.controls, const [SceneButton('beginner')]);
    });

    test('a dropdown replaces only what it names, never another dropdown', () {
      final scene = _scene([
        {
          'label': 'one',
          'options': ['a'],
          'replaces': ['one', 'two', 7],
        },
        {
          'label': 'two',
          'options': ['b'],
        },
        'a',
      ]);
      expect(scene.controls, hasLength(3));
    });

    test('options are capped and repeats dropped', () {
      final scene = _scene([
        {
          'options': ['a', 'a', for (var i = 0; i < 40; i++) 'o$i'],
        },
      ]);
      final select = scene.controls.single as SceneSelect;
      expect(select.options, hasLength(SceneSelect.maxOptions));
      expect(select.options.first, 'a');
      expect(select.label, 'choose');
    });
  });

  group('choosing', () {
    final scene = _scene([
      {'label': 'board size', 'value': 'beginner', 'options': _sizes},
    ]);

    testWidgets('it shows the choice in force and names itself', (
      tester,
    ) async {
      await _pump(tester, scene);

      expect(find.text('beginner'), findsOneWidget);
      expect(
        find.bySemanticsLabel('board size, currently beginner'),
        findsOneWidget,
      );
    });

    testWidgets('another option sends that option as the action', (
      tester,
    ) async {
      final sent = await _pump(tester, scene);

      await tester.tap(find.text('beginner'), kind: PointerDeviceKind.mouse);
      await _settle(tester);
      for (final option in _sizes) {
        expect(find.text(option), findsWidgets, reason: option);
      }
      await tester.tap(find.text('expert'), kind: PointerDeviceKind.mouse);
      await _settle(tester);

      expect(sent, ['expert']);
    });

    testWidgets('the option already in force sends nothing', (tester) async {
      final sent = await _pump(tester, scene);

      await tester.tap(find.text('beginner'), kind: PointerDeviceKind.mouse);
      await _settle(tester);
      await tester.tap(
        find.text('beginner').last,
        kind: PointerDeviceKind.mouse,
      );
      await _settle(tester);

      expect(sent, isEmpty);
    });
  });

  group('the menu stays under its button', () {
    final scene = _scene([
      {'label': 'board size', 'value': 'beginner', 'options': _sizes},
    ]);
    final menu = find.ancestor(
      of: find.text('expert'),
      matching: find.byWidgetPredicate(
        (w) => w is Material && w.color == AppTokens.dark.surfaceRaised,
      ),
    );

    for (final (side, alignment) in [
      ('left', Alignment.topLeft),
      ('right', Alignment.topRight),
    ]) {
      testWidgets('with the button in the $side half of the window', (
        tester,
      ) async {
        await _pump(tester, scene, alignment: alignment);
        final button = tester.getRect(find.text('beginner'));

        await tester.tap(find.text('beginner'), kind: PointerDeviceKind.mouse);
        await _settle(tester);
        final dropped = tester.getRect(menu.first);

        expect(dropped.top, greaterThanOrEqualTo(button.bottom));
        expect(dropped.left, lessThan(button.right), reason: 'overlaps');
        expect(dropped.right, greaterThan(button.left), reason: 'overlaps');
      });
    }
  });
}
