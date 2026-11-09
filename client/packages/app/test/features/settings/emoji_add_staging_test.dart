// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The staging area inside the add-emoji dialog: pre-staged files, rename,
/// duplicate and invalid names, removal, paste and the one import.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/screens/admin/emoji_intake.dart';
import 'package:slimm_design_system/design_system.dart';

import 'emoji_add_harness.dart';

const _clipboard = MethodChannel('top.npcserver.slimm/clipboard_image');

Future<void> _settle(WidgetTester tester) =>
    tester.pump(const Duration(milliseconds: 100));

const _huh = api.CustomEmoji(
  id: 'e-huh',
  name: 'huh',
  uploaderId: 'u',
  createdAt: 0,
);

Finder _field(String fileName) => find.byKey(ValueKey('emoji-name-$fileName'));

String _typed(WidgetTester tester, String fileName) =>
    tester.widget<AppInput>(_field(fileName)).controller!.text;

bool _importDisabled(WidgetTester tester, String label) =>
    tester.widget<AppButton>(find.widgetWithText(AppButton, label)).disabled;

EmojiHarness _singleOk({List<api.CustomEmoji> existing = const []}) =>
    EmojiHarness(
      existing: existing,
      onSingle: (r) =>
          emojiJson(emojiRow(r.url.queryParameters['name']!), status: 201),
      onBulk: (r) =>
          emojiJson([for (final n in bulkNames(r)) emojiRow(n)], status: 201),
    );

void main() {
  testWidgets('files handed to the dialog are staged with sanitised names', (
    tester,
  ) async {
    final h = EmojiHarness();
    await h.pump(tester, initial: [emojiPick('Party Parrot.png')]);
    await _settle(tester);

    final field = tester.widget<AppInput>(
      find.byKey(const ValueKey('emoji-name-Party Parrot.png')),
    );
    expect(field.controller!.text, 'party_parrot');
    expect(find.text('Import 1 emoji'), findsOneWidget);
  });

  testWidgets('a duplicate or invalid name shows inline and blocks import', (
    tester,
  ) async {
    final h = EmojiHarness();
    await h.pump(tester, initial: [emojiPick('aa.png'), emojiPick('bb.png')]);
    await _settle(tester);

    await tester.enterText(
      find.byKey(const ValueKey('emoji-name-bb.png')),
      'aa',
    );
    await _settle(tester);
    expect(find.text('Another image has this name.'), findsOneWidget);

    await tester.tap(find.text('Import 2 emoji'));
    await _settle(tester);
    expect(h.bulks, isEmpty);
    expect(h.singles, isEmpty);
  });

  testWidgets('removing a staged file drops it and import covers the rest', (
    tester,
  ) async {
    final h = EmojiHarness(
      onBulk: (r) =>
          emojiJson([for (final n in bulkNames(r)) emojiRow(n)], status: 201),
    );
    await h.pump(
      tester,
      initial: [emojiPick('aa.png'), emojiPick('bb.png'), emojiPick('cc.png')],
    );
    await _settle(tester);

    await tester.tap(find.byKey(const ValueKey('emoji-remove-bb.png')));
    await _settle(tester);
    await tester.tap(find.text('Import 2 emoji'));
    await _settle(tester);

    expect(h.bulks, hasLength(1));
    expect(bulkNames(h.bulks.single), ['aa', 'cc']);
  });

  testWidgets('a pasted clipboard image is staged', (tester) async {
    final h = EmojiHarness();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _clipboard,
      (call) async => call.method == 'readImage' ? emojiTestPng : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _clipboard,
        null,
      ),
    );
    await h.pump(tester);

    await tester.tap(find.text('Paste image'));
    await _settle(tester);

    expect(
      find.byKey(const ValueKey('emoji-name-pasted-1.png')),
      findsOneWidget,
    );
    expect(find.text('Import 1 emoji'), findsOneWidget);
  });

  for (final size in const [Size(1280, 800), Size(390, 844)]) {
    final at = '${size.width.toInt()}';

    testWidgets('a file named after an existing emoji is staged to rename '
        'at $at', (tester) async {
      final h = _singleOk(existing: const [_huh]);
      h.picks = [emojiPick('huh.gif')];
      await h.pump(tester, size: size);
      await h.choose(tester);

      expect(_field('huh.gif'), findsOneWidget);
      expect(_typed(tester, 'huh.gif'), 'huh');
      expect(find.text('Already taken.'), findsOneWidget);
      expect(find.textContaining('is already used'), findsNothing);
      expect(_importDisabled(tester, 'Import 1 emoji'), isTrue);

      await tester.enterText(_field('huh.gif'), 'huh_2');
      await _settle(tester);
      expect(find.text('Already taken.'), findsNothing);
      expect(_importDisabled(tester, 'Import 1 emoji'), isFalse);

      await tester.tap(find.text('Import 1 emoji'));
      await _settle(tester);
      expect(h.singles.single.url.queryParameters['name'], 'huh_2');
      expect(tester.takeException(), isNull);
    });

    testWidgets('two files with one stem both stage, the second flagged at '
        '$at', (tester) async {
      final h = _singleOk();
      await h.pump(
        tester,
        size: size,
        initial: [emojiPick('Smile.png'), emojiPick('smile.gif')],
      );
      await _settle(tester);

      expect(_typed(tester, 'Smile.png'), 'smile');
      expect(_typed(tester, 'smile.gif'), 'smile');
      expect(find.text('Another image has this name.'), findsOneWidget);
      expect(find.textContaining('is already used'), findsNothing);

      await tester.enterText(_field('smile.gif'), 'smile_2');
      await _settle(tester);
      expect(find.text('Another image has this name.'), findsNothing);
      expect(_importDisabled(tester, 'Import 2 emoji'), isFalse);
    });

    testWidgets('a name taken by a zip entry stages it too at $at', (
      tester,
    ) async {
      final h = _singleOk(existing: const [_huh]);
      h.picks = [
        EmojiPick(
          fileName: 'pack.zip',
          bytes: buildEmojiZip({
            'huh.png': emojiTestPng,
            'ok.png': emojiTestPng,
          }),
        ),
      ];
      await h.pump(tester, size: size);
      await h.choose(tester);

      expect(_field('huh.png'), findsOneWidget);
      expect(_field('ok.png'), findsOneWidget);
      expect(find.text('Already taken.'), findsOneWidget);
    });

    testWidgets('one bad row blocks nothing else and can be fixed or removed '
        'at $at', (tester) async {
      final h = _singleOk(existing: const [_huh]);
      await h.pump(
        tester,
        size: size,
        initial: [
          emojiPick('!!!.png'),
          emojiPick('ok.png'),
          emojiPick('huh.png'),
        ],
      );
      await _settle(tester);

      expect(find.text('Import 3 emoji'), findsOneWidget);
      expect(_importDisabled(tester, 'Import 3 emoji'), isTrue);
      expect(_typed(tester, '!!!.png'), isEmpty);
      expect(
        find.text('Use letters, numbers and underscores.'),
        findsOneWidget,
      );
      expect(find.text('Already taken.'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('emoji-remove-!!!.png')));
      await _settle(tester);
      await tester.enterText(_field('huh.png'), 'huh_2');
      await _settle(tester);
      expect(_importDisabled(tester, 'Import 2 emoji'), isFalse);

      await tester.tap(find.text('Import 2 emoji'));
      await _settle(tester);
      expect(bulkNames(h.bulks.single), ['ok', 'huh_2']);
    });

    testWidgets('a name past the limit says too long, not invalid at $at', (
      tester,
    ) async {
      final h = _singleOk();
      final longName = 'party_parrot_dance_remix_${'x' * 20}';
      await h.pump(tester, size: size, initial: [emojiPick('$longName.gif')]);
      await _settle(tester);

      expect(_typed(tester, '$longName.gif'), longName);
      expect(find.text('Too long, 32 characters at most.'), findsOneWidget);
      expect(find.text('Use letters, numbers and underscores.'), findsNothing);

      await tester.enterText(_field('$longName.gif'), 'party_parrot');
      await _settle(tester);
      expect(find.text('Too long, 32 characters at most.'), findsNothing);
      expect(_importDisabled(tester, 'Import 1 emoji'), isFalse);
      expect(tester.takeException(), isNull);
    });
  }
}
