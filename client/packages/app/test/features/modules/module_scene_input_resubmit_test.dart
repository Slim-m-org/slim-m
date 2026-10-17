// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A scene text field is ready for the next entry the moment one is sent.
///
/// word-guess ("type a word") answers every guess with a fresh scene that
/// carries the same input and no value, and the owner had to click back in and
/// delete the last word each time. Driven through the real view so the
/// round trip, the re-render and the keyboard action are all in play.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/modules/widgets/module_scene.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_view.dart';
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

  group('while a reply is pending', () {
    late Completer<String> reply;
    late ValueNotifier<String> shown;
    late List<String> actions;

    Future<void> mountPending(WidgetTester tester) async {
      reply = Completer<String>();
      shown = ValueNotifier(_scene(used: 0));
      addTearDown(shown.dispose);
      actions = [];
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: SizedBox(
              width: 500,
              child: ValueListenableBuilder(
                valueListenable: shown,
                builder: (_, json, _) => ModuleSceneView(
                  initial: parseModuleScene(json)!,
                  runCommand: (raw) async {
                    actions.add(jsonDecode(raw)['action'] as String);
                    return api.RunModuleCommandResult(
                      ok: true,
                      output: await reply.future,
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'crane');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pump();
    }

    testWidgets('text typed ahead survives the reply', (tester) async {
      await mountPending(tester);
      await tester.enterText(find.byType(TextField), 'sla');
      reply.complete(_scene(used: 1, value: 'CRANE'));
      await tester.pumpAndSettle();
      expect(_field(tester).textEditingValue.text, 'sla');
    });

    testWidgets('an identical reply leaves typed text alone', (tester) async {
      await mountPending(tester);
      await tester.enterText(find.byType(TextField), 'sla');
      reply.complete(_scene(used: 1));
      await tester.pumpAndSettle();
      expect(_field(tester).textEditingValue.text, 'sla');
    });

    testWidgets('a stray scene does not use up the reply', (tester) async {
      await mountPending(tester);
      shown.value = _scene(used: 5);
      await tester.pump();
      reply.complete(_scene(used: 1, value: 'CRANE'));
      await tester.pumpAndSettle();
      expect(_field(tester).textEditingValue.text, 'CRANE');
    });
  });

  testWidgets('an empty or blank entry is not sent', (tester) async {
    final actions = await _mount(tester, (used) => _scene(used: used));
    await tester.tap(find.byType(TextField));
    await _submit(tester, '   ');
    expect(actions, isEmpty);
    expect(_field(tester).widget.focusNode.hasFocus, isTrue);
  });

  testWidgets('a failed command does not wipe what is typed next', (
    tester,
  ) async {
    var fail = true;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: SizedBox(
            width: 500,
            child: ModuleSceneView(
              initial: parseModuleScene(_scene(used: 0))!,
              runCommand: (_) async => fail
                  ? throw StateError('down')
                  : api.RunModuleCommandResult(
                      ok: true,
                      output: _scene(used: 1, value: 'CRANE'),
                    ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextField));
    await _submit(tester, 'crane');
    fail = false;
    await tester.enterText(find.byType(TextField), 'slate');
    await tester.pumpAndSettle();
    expect(_field(tester).textEditingValue.text, 'slate');
  });
}
