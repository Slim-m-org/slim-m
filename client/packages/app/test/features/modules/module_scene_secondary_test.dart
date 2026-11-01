// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A secondary press on a scene: right click with a mouse, long press with a
/// finger. An op names it with `alt`, and a scene with none keeps reading a
/// held tap as a tap.
library;

import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/modules/widgets/module_scene.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_painter.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_view.dart';
import 'package:slimm_design_system/design_system.dart';

String _board({bool withAlt = true}) => jsonEncode({
  r'$slim': 'scene/1',
  'width': 100,
  'height': 100,
  'ops': [
    {
      'op': 'cells',
      'cols': 4,
      'rows': 4,
      'data': '0' * 16,
      'palette': ['sunken'],
      'tap': 'dig',
      if (withAlt) 'alt': 'flag',
    },
  ],
  'state': 's',
  'live': true,
});

ModuleScene _scene({bool withAlt = true}) =>
    parseModuleScene(_board(withAlt: withAlt))!;

Future<List<String>> _drive(
  WidgetTester tester,
  Future<void> Function(Offset topLeft) gesture, {
  bool withAlt = true,
}) async {
  final actions = <String>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            child: ModuleSceneView(
              initial: _scene(withAlt: withAlt),
              runCommand: (input) async {
                actions.add(jsonDecode(input)['action'] as String);
                return api.RunModuleCommandResult(
                  ok: true,
                  output: _board(withAlt: withAlt),
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
  await gesture(tester.getTopLeft(board.last));
  await tester.pumpAndSettle();
  return actions;
}

void main() {
  const size = Size(100, 100);

  group('the contract', () {
    test('a cells op keeps its alt, and a primary press ignores it', () {
      final op = _scene().ops.single as CellsOp;
      expect((op.tap, op.alt), ('dig', 'flag'));
      expect(sceneTapAction(_scene(), const Offset(60, 30), size), 'dig:1,2');
    });

    test('a secondary press names the same cell with the alt action', () {
      expect(
        sceneTapAction(_scene(), const Offset(60, 30), size, secondary: true),
        'flag:1,2',
      );
    });

    test('a secondary press on an op with no alt does nothing', () {
      expect(
        sceneTapAction(
          _scene(withAlt: false),
          const Offset(60, 30),
          size,
          secondary: true,
        ),
        isNull,
      );
    });

    test('a rect answers a secondary press with its own alt', () {
      final scene = parseModuleScene(
        jsonEncode({
          r'$slim': 'scene/1',
          'width': 100,
          'height': 100,
          'ops': [
            {
              'op': 'rect',
              'x': 0,
              'y': 0,
              'w': 50,
              'h': 50,
              'tap': 'open',
              'alt': 'mark',
            },
          ],
        }),
      )!;
      expect(scene.hasSecondary, isTrue);
      expect(
        sceneTapAction(scene, const Offset(10, 10), size, secondary: true),
        'mark',
      );
      expect(sceneTapAction(scene, const Offset(10, 10), size), 'open');
    });

    test('only a scene that names an alt asks for the gesture', () {
      expect(_scene().hasSecondary, isTrue);
      expect(_scene(withAlt: false).hasSecondary, isFalse);
    });
  });

  group('on the board', () {
    testWidgets('a tap digs and a right click flags the same cell', (
      tester,
    ) async {
      final actions = await _drive(tester, (origin) async {
        await tester.tapAt(origin + const Offset(50, 50));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tapAt(
          origin + const Offset(250, 150),
          buttons: kSecondaryButton,
          kind: PointerDeviceKind.mouse,
        );
      });
      expect(actions, ['dig:0,0', 'flag:1,2']);
    });

    testWidgets('a long press with a finger flags', (tester) async {
      final actions = await _drive(tester, (origin) async {
        await tester.longPressAt(origin + const Offset(150, 250));
      });
      expect(actions, ['flag:2,1']);
    });

    testWidgets('a right click on a scene with no alt sends nothing', (
      tester,
    ) async {
      final actions = await _drive(tester, (origin) async {
        await tester.tapAt(
          origin + const Offset(50, 50),
          buttons: kSecondaryButton,
          kind: PointerDeviceKind.mouse,
        );
      }, withAlt: false);
      expect(actions, isEmpty);
    });

    testWidgets('a held tap on a scene with no alt still taps', (tester) async {
      final actions = await _drive(tester, (origin) async {
        await tester.longPressAt(origin + const Offset(50, 50));
      }, withAlt: false);
      expect(actions, ['dig:0,0']);
    });
  });
}
