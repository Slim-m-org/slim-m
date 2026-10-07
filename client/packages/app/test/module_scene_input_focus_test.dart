// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A text field inside a scene keeps its focus and its keys: the grid's
/// keyboard handling never claims a pointer down on the field, nor Space and
/// Enter typed into it.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/widgets/module_scene.dart';
import 'package:slimm_app/src/widgets/module_scene_view.dart';
import 'package:slimm_design_system/design_system.dart';

String _json({required bool grid}) => jsonEncode({
  r'$slim': 'scene/1',
  'width': 100,
  'height': 100,
  'ops': [
    if (grid)
      {
        'op': 'cells',
        'cols': 4,
        'rows': 4,
        'data': '................',
        'tap': 'toggle',
      },
    {'op': 'input', 'x': 10, 'y': 70, 'w': 80, 'submit': 'guess'},
  ],
  'state': 's0',
});

Future<List<String>> _mount(WidgetTester tester, {required bool grid}) async {
  final actions = <String>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            child: ModuleSceneView(
              initial: parseModuleScene(_json(grid: grid))!,
              runCommand: (input) async {
                actions.add(jsonDecode(input)['action'] as String);
                return api.RunModuleCommandResult(
                  ok: true,
                  output: _json(grid: grid),
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return actions;
}

void main() {
  testWidgets(
    'pointer down on a focused field keeps its focus (no grid at all)',
    (tester) async {
      await _mount(tester, grid: false);
      final field = find.byType(TextField);
      await tester.tap(field);
      await tester.pumpAndSettle();
      final editable = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      expect(
        editable.widget.focusNode.hasFocus,
        isTrue,
        reason: 'precondition',
      );

      final g = await tester.startGesture(tester.getCenter(field));
      await tester.pump();
      expect(
        editable.widget.focusNode.hasFocus,
        isTrue,
        reason: 'tapping the focused field to move the caret must not blur it',
      );
      await g.up();
    },
  );

  testWidgets('space in a focused field does not activate the grid', (
    tester,
  ) async {
    final actions = await _mount(tester, grid: true);
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    final editable = tester.state<EditableTextState>(find.byType(EditableText));
    expect(editable.widget.focusNode.hasFocus, isTrue);
    actions.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(actions, isEmpty);
  });
}
