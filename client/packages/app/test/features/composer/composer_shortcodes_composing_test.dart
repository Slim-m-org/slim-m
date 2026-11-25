// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A `:name:` shortcode is never converted while an IME composition is open,
/// since rewriting the field would cancel the candidate.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_shortcodes.dart';

Future<TextEditingController> _pump(WidgetTester tester) async {
  final controller = TextEditingController(text: ':smile');
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: Material(
          child: ComposerShortcodes(
            controller: controller,
            child: TextField(controller: controller),
          ),
        ),
      ),
    ),
  );
  return controller;
}

void main() {
  testWidgets('composing text is left alone, then converts once it ends', (
    tester,
  ) async {
    final controller = await _pump(tester);

    controller.value = const TextEditingValue(
      text: ':smile:',
      selection: TextSelection.collapsed(offset: 7),
      composing: TextRange(start: 0, end: 7),
    );
    await tester.pump();
    expect(controller.text, ':smile:');

    controller.value = const TextEditingValue(
      text: ':smile:',
      selection: TextSelection.collapsed(offset: 7),
    );
    await tester.pump();
    expect(controller.text, isNot(':smile:'));
  });

  testWidgets('without a composition the same text converts', (tester) async {
    final controller = await _pump(tester);

    controller.value = const TextEditingValue(
      text: ':smile:',
      selection: TextSelection.collapsed(offset: 7),
    );
    await tester.pump();
    expect(controller.text, isNot(':smile:'));
  });
}
