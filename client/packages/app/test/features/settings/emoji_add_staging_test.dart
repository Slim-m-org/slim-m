// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The staging area inside the add-emoji dialog: pre-staged files, rename,
/// duplicate and invalid names, removal, paste and the one import.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

import 'emoji_add_harness.dart';

const _clipboard = MethodChannel('top.npcserver.slimm/clipboard_image');

Future<void> _settle(WidgetTester tester) =>
    tester.pump(const Duration(milliseconds: 100));

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
}
