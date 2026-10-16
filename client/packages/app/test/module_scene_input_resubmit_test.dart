// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A scene text field is ready for the next entry the moment one is sent.
///
/// word-guess ("type a word") answers every guess with a fresh scene that
/// carries the same input and no value, and the owner had to click back in and
/// delete the last word each time. Driven through the real view so the
/// round trip, the re-render and the keyboard action are all in play.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/widgets/module_scene.dart';
import 'package:slimm_app/src/widgets/module_scene_view.dart';
import 'package:slimm_design_system/design_system.dart';

String _scene({required int used, bool input = true, String? value}) =>
    jsonEncode({
      r'$slim': 'scene/1',
      'width': 100,
      'height': 100,
      'ops': [
        {'op': 'rect', 'x': 20, 'y': 4, 'w': 60, 'h': 60, 'fill': 'sunken'},
        if (input)
          {
            'op': 'input',
            'x': 21,
            'y': 80,
            'w': 58,
            'submit': 'guess',
            'max': 5,
            'value': ?value,
          },
      ],
      'status': '$used of 6 tries used',
      'state': 'g$used',
    });

Future<List<String>> _mount(
  WidgetTester tester,
  String Function(int used) next,
) async {
  final actions = <String>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: Scaffold(
        body: SizedBox(
          width: 500,
          child: ModuleSceneView(
            initial: parseModuleScene(_scene(used: 0))!,
            runCommand: (raw) async {
              actions.add(jsonDecode(raw)['action'] as String);
              return api.RunModuleCommandResult(
                ok: true,
                output: next(actions.length),
              );
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return actions;
}

Future<void> _submit(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
}

EditableTextState _field(WidgetTester tester) =>
    tester.state<EditableTextState>(find.byType(EditableText));

void main() {
  testWidgets('a sent word is cleared and the field keeps focus', (
    tester,
  ) async {
    final actions = await _mount(tester, (used) => _scene(used: used));
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    await _submit(tester, 'crane');
    expect(actions, ['guess:crane']);
    expect(_field(tester).textEditingValue.text, isEmpty);
    expect(_field(tester).widget.focusNode.hasFocus, isTrue);

    await tester.enterText(find.byType(TextField), 'slate');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(actions, ['guess:crane', 'guess:slate']);
    expect(_field(tester).textEditingValue.text, isEmpty);
    expect(_field(tester).widget.focusNode.hasFocus, isTrue);
  });

  testWidgets('a value the module sends back replaces the cleared field', (
    tester,
  ) async {
    await _mount(tester, (used) => _scene(used: used, value: 'CRANE'));
    await tester.tap(find.byType(TextField));
    await _submit(tester, 'crane ');
    expect(_field(tester).textEditingValue.text, 'CRANE');
    expect(_field(tester).widget.focusNode.hasFocus, isTrue);
  });

  testWidgets('a scene that drops the input leaves no field behind', (
    tester,
  ) async {
    await _mount(tester, (used) => _scene(used: used, input: false));
    await tester.tap(find.byType(TextField));
    await _submit(tester, 'crane');
    expect(find.byType(TextField), findsNothing);
  });
}
