// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Enter presses a focused control under the web build's key map, where
/// Flutter sends it as a ButtonActivateIntent that only Material buttons answer.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/enter_activates_buttons.dart';
import 'package:slimm_design_system/design_system.dart';

/// The two entries `WidgetsApp._defaultWebShortcuts` binds Enter to.
const _webEnter = <ShortcutActivator, Intent>{
  SingleActivator(LogicalKeyboardKey.enter): ButtonActivateIntent(),
  SingleActivator(LogicalKeyboardKey.numpadEnter): ButtonActivateIntent(),
};

Future<void> _pump(WidgetTester tester, Widget body) => tester.pumpWidget(
  MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    shortcuts: {...WidgetsApp.defaultShortcuts, ..._webEnter},
    builder: (context, child) => EnterActivatesButtons(child: child!),
    home: Scaffold(body: Center(child: body)),
  ),
);

void main() {
  testWidgets('Enter presses a focused AppButton and AppIconButton', (
    tester,
  ) async {
    final pressed = <String>[];
    final button = FocusNode();
    final icon = FocusNode();
    addTearDown(button.dispose);
    addTearDown(icon.dispose);
    await _pump(
      tester,
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppButton(
            label: 'Skip setup',
            focusNode: button,
            onPressed: () => pressed.add('skip'),
          ),
          AppIconButton(
            icon: AppIcons.poll,
            semanticLabel: 'Create a poll',
            focusNode: icon,
            onPressed: () => pressed.add('poll'),
          ),
        ],
      ),
    );

    button.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    icon.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);

    expect(pressed, ['skip', 'poll']);
  });

  testWidgets('Enter in a text field stays the field\'s own', (tester) async {
    final submitted = <String>[];
    final field = FocusNode();
    addTearDown(field.dispose);
    var pressed = 0;
    await _pump(
      tester,
      Actions(
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) => pressed++,
          ),
        },
        child: SizedBox(
          width: 300,
          child: TextField(focusNode: field, onSubmitted: submitted.add),
        ),
      ),
    );

    field.requestFocus();
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(pressed, 0, reason: 'the enclosing ActivateIntent must not run');
    expect(submitted, ['hello']);
  });

  testWidgets('Enter on a disabled button does nothing', (tester) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    await _pump(
      tester,
      AppButton(label: 'Send poll', focusNode: node, disabled: true),
    );
    node.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(tester.takeException(), isNull);
  });
}
