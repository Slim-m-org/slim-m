// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Up in an empty composer edits the last message, but Up with a modifier held
/// is someone else's shortcut (Alt+Up is the previous channel on the web) and
/// passes through.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_autocomplete_controller.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_key_handler.dart';

Future<(List<String>, List<String>)> _pump(WidgetTester tester) async {
  final edits = <String>[];
  final shell = <String>[];
  final text = TextEditingController();
  addTearDown(text.dispose);
  final handler = ComposerKeyHandler(
    text: text,
    autocomplete: ComposerAutocompleteController(),
    onPasteChord: () {},
    onEditLast: () async => edits.add('edit'),
    onAccept: (_) {},
  );
  final node = FocusNode();
  addTearDown(node.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true): () =>
              shell.add('previous channel'),
        },
        child: Focus(
          focusNode: node,
          autofocus: true,
          onKeyEvent: handler.handle,
          child: const SizedBox(),
        ),
      ),
    ),
  );
  await tester.pump();
  return (edits, shell);
}

void main() {
  testWidgets('Up in an empty composer edits the last message', (tester) async {
    final (edits, shell) = await _pump(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);

    expect(edits, ['edit']);
    expect(shell, isEmpty);
  });

  testWidgets('Alt+Up in an empty composer reaches the shell shortcut', (
    tester,
  ) async {
    final (edits, shell) = await _pump(tester);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);

    expect(edits, isEmpty);
    expect(shell, ['previous channel']);
  });
}
