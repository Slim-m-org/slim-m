// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Typing a completed `:name:` in the composer: a standard emoji becomes its
/// glyph at the closing colon, a custom one gets a preview above the field,
/// and the stored text stays what the member typed everywhere else.
library;

import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/emoji/providers/emoji_catalog_provider.dart';
import 'package:slimm_app/src/features/emoji/widgets/custom_emoji_image.dart';

import '../composer/composer_harness.dart' hide custom;
import '../composer/composer_harness.dart' as harness show custom;

const emoji = harness.custom;

const _bug = '\u{1F41B}';

final _field = find.byWidgetPredicate((w) => w is TextField);
final _preview = find.byWidgetPredicate((w) => w is CustomEmojiImage);

/// A Space emoji index that counts how often its names are copied out.
class _CountingIndex extends MapBase<String, String> {
  final _inner = {'party': 'e-party'};
  int nameCopies = 0;

  @override
  Iterable<String> get keys {
    nameCopies += 1;
    return _inner.keys;
  }

  @override
  bool containsKey(Object? key) => _inner.containsKey(key);

  @override
  bool get isEmpty => _inner.isEmpty;

  @override
  bool get isNotEmpty => _inner.isNotEmpty;

  @override
  int get length => _inner.length;

  @override
  String? operator [](Object? key) => _inner[key];

  @override
  void operator []=(String key, String value) => _inner[key] = value;

  @override
  void clear() => _inner.clear();

  @override
  String? remove(Object? key) => _inner.remove(key);
}

void main() {
  late TextEditingController controller;
  late Sends sends;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    controller = TextEditingController();
    sends = Sends();
  });

  tearDown(() => controller.dispose());

  Future<void> pump(WidgetTester tester, {List<String> custom = const []}) =>
      tester.pumpWidget(
        composerHarness(
          controller: controller,
          sends: sends,
          platform: TargetPlatform.linux,
          customEmoji: [for (final n in custom) emoji(n)],
        ),
      );

  testWidgets('the closing colon turns a standard shortcode into its glyph', (
    tester,
  ) async {
    await pump(tester);

    await tester.enterText(find.byType(TextField), 'a :bug');
    await tester.enterText(find.byType(TextField), 'a :bug:');
    await tester.pump();

    expect(controller.text, 'a $_bug');
    expect(controller.selection.baseOffset, 'a $_bug'.length);
  });

  testWidgets('backspace right after the conversion restores the shortcode', (
    tester,
  ) async {
    await pump(tester);
    await tester.enterText(find.byType(TextField), ':bug');
    await tester.enterText(find.byType(TextField), ':bug:');
    await tester.pump();
    expect(controller.text, _bug);

    await tester.enterText(find.byType(TextField), '');
    await tester.pump();

    expect(controller.text, ':bug:');
    expect(
      controller.selection.baseOffset,
      ':bug:'.length,
      reason: 'it must not convert straight back',
    );
  });

  testWidgets('a name that is not a standard emoji stays as typed', (
    tester,
  ) async {
    await pump(tester);

    await tester.enterText(find.byType(TextField), 'at 10:30:');
    await tester.enterText(find.byType(TextField), ':nonsense');
    await tester.enterText(find.byType(TextField), ':nonsense:');
    await tester.pump();

    expect(controller.text, ':nonsense:');
  });

  testWidgets('code spans and fences are never converted', (tester) async {
    await pump(tester);

    await tester.enterText(find.byType(TextField), '`x :bug');
    await tester.enterText(find.byType(TextField), '`x :bug:');
    await tester.pump();
    expect(controller.text, '`x :bug:');

    await tester.enterText(find.byType(TextField), '```\n:bug');
    await tester.enterText(find.byType(TextField), '```\n:bug:');
    await tester.pump();
    expect(controller.text, '```\n:bug:');
  });

  testWidgets('a custom emoji keeps its text and shows a preview', (
    tester,
  ) async {
    await pump(tester, custom: ['bug']);
    expect(find.byType(CustomEmojiImage), findsNothing);

    await tester.enterText(find.byType(TextField), ':bug');
    await tester.enterText(find.byType(TextField), ':bug:');
    await tester.pump();

    expect(controller.text, ':bug:', reason: 'the Space emoji wins the name');
    expect(find.byType(CustomEmojiImage), findsOneWidget);
    expect(find.text(':bug:'), findsWidgets);
  });

  testWidgets('typing copies the Space emoji names once, not per keystroke', (
    tester,
  ) async {
    final index = _CountingIndex();
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.linux,
        extraOverrides: [customEmojiIndexProvider.overrideWithValue(index)],
      ),
    );

    var draft = '';
    for (final ch in 'hello :party: there'.split('')) {
      draft += ch;
      await tester.enterText(_field, draft);
    }
    await tester.pump();

    expect(_preview, findsOneWidget);
    expect(index.nameCopies, 1);
  });

  testWidgets('the preview goes when the shortcode does', (tester) async {
    await pump(tester, custom: ['bug']);
    await tester.enterText(_field, ':bug:');
    await tester.pump();
    expect(_preview, findsOneWidget);

    await tester.enterText(_field, 'bug');
    await tester.pump();

    expect(_preview, findsNothing);
  });
}
