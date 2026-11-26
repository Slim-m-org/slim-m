// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The inline emoji field: the caret steps over an emoji, a backspace takes it whole, and an IME composing elsewhere leaves it drawn.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/emoji/widgets/inline_emoji_controller.dart';
import 'package:slimm_app/src/features/emoji/providers/emoji_catalog_provider.dart';
import 'package:slimm_design_system/design_system.dart';

final _png = Uint8List.fromList(
  base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
    'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  ),
);

const _fieldKey = Key('emoji-field');
const _blobby = ':blobby:';

Future<InlineEmojiController> _field(WidgetTester tester, String text) async {
  final controller = InlineEmojiController(
    text: text,
    index: () => const {'blobby': 'e-blobby'},
  );
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [customEmojiImageProvider.overrideWith((ref, id) => _png)],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: TextField(
            key: _fieldKey,
            controller: controller,
            autofocus: true,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return controller;
}

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pump();
}

int _widgetSpans(InlineEmojiController controller, BuildContext context) {
  final root = controller.buildTextSpan(context: context, withComposing: true);
  var count = 0;
  root.visitChildren((span) {
    if (span is WidgetSpan) count++;
    return true;
  });
  return count;
}

void main() {
  testWidgets('Right steps over an emoji in one press', (tester) async {
    final controller = await _field(tester, 'a${_blobby}b');
    controller.selection = const TextSelection.collapsed(offset: 1);
    await tester.pump();

    await _press(tester, LogicalKeyboardKey.arrowRight);

    expect(controller.selection.baseOffset, 1 + _blobby.length);
  });

  testWidgets('Left steps back over an emoji in one press', (tester) async {
    final controller = await _field(tester, 'a${_blobby}b');
    controller.selection = const TextSelection.collapsed(
      offset: 1 + _blobby.length,
    );
    await tester.pump();

    await _press(tester, LogicalKeyboardKey.arrowLeft);

    expect(controller.selection.baseOffset, 1);
  });

  testWidgets('a tap inside the hidden characters lands on the nearer edge', (
    tester,
  ) async {
    final controller = await _field(tester, 'a${_blobby}b');
    controller.selection = const TextSelection.collapsed(offset: 0);
    await tester.pump();

    controller.value = controller.value.copyWith(
      selection: const TextSelection.collapsed(offset: 3),
    );

    expect(controller.selection.baseOffset, 1);
    controller.value = controller.value.copyWith(
      selection: const TextSelection.collapsed(offset: 7),
    );
    expect(controller.selection.baseOffset, 1 + _blobby.length);
  });

  testWidgets('Backspace after an emoji removes the whole shortcode', (
    tester,
  ) async {
    final controller = await _field(tester, 'a${_blobby}b');
    controller.selection = const TextSelection.collapsed(
      offset: 1 + _blobby.length,
    );
    await tester.pump();

    await _press(tester, LogicalKeyboardKey.backspace);

    expect(controller.text, 'ab');
    expect(controller.selection.baseOffset, 1);
  });

  testWidgets('Delete before an emoji removes the whole shortcode', (
    tester,
  ) async {
    final controller = await _field(tester, 'a${_blobby}b');
    controller.selection = const TextSelection.collapsed(offset: 1);
    await tester.pump();

    await _press(tester, LogicalKeyboardKey.delete);

    expect(controller.text, 'ab');
  });

  testWidgets('an emoji stays drawn while another word is being composed', (
    tester,
  ) async {
    final controller = await _field(tester, '$_blobby wor');
    controller.value = controller.value.copyWith(
      composing: const TextRange(start: 9, end: 12),
    );
    await tester.pump();

    expect(_widgetSpans(controller, tester.element(find.byKey(_fieldKey))), 1);
  });

  testWidgets('an emoji the keyboard is composing inside is left as text', (
    tester,
  ) async {
    final controller = await _field(tester, '$_blobby wor');
    controller.value = controller.value.copyWith(
      composing: const TextRange(start: 2, end: 6),
    );
    await tester.pump();

    expect(_widgetSpans(controller, tester.element(find.byKey(_fieldKey))), 0);
  });
}
