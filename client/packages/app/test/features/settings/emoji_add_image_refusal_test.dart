// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A batch the server refuses for its images, not their names: every bad
/// image says why on its own row in one round trip, and removing them lets
/// the rest go.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

import 'emoji_add_harness.dart';

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Finder _field(String fileName) => find.byKey(ValueKey('emoji-name-$fileName'));

bool _disabled(WidgetTester tester, String label) =>
    tester.widget<AppButton>(find.widgetWithText(AppButton, label)).disabled;

void _expectUnder(WidgetTester tester, String text, String row, String next) {
  final problem = tester.getRect(find.text(text));
  expect(problem.top, greaterThan(tester.getRect(_field(row)).top));
  expect(problem.top, lessThan(tester.getRect(_field(next)).top));
}

void main() {
  testWidgets('a wrong type and an oversized image are both flagged on their '
      'own rows, and removing them sends the rest', (tester) async {
    var calls = 0;
    final h = EmojiHarness(
      picks: [
        for (final n in ['aaa', 'bbb', 'text_as', 'huge', 'eee', 'fff'])
          emojiPick('$n.png'),
      ],
      onBulk: (r) {
        if (++calls > 1) {
          return emojiJson([
            for (final n in bulkNames(r)) emojiRow(n),
          ], status: 201);
        }
        return emojiJson({
          'error': 'image 3 (text_as): unsupported emoji type',
          'item_index': 2,
          'item_code': 'unsupported_type',
          'items': [
            {
              'index': 2,
              'code': 'unsupported_type',
              'error': 'image 3 (text_as): unsupported emoji type',
            },
            {
              'index': 3,
              'code': 'too_many_pixels',
              'error':
                  'image 4 (huge): emoji must be at most 1024 pixels on a side',
            },
          ],
        }, status: 400);
      },
    );
    await h.pump(tester);
    await h.choose(tester);

    await tester.tap(find.text('Create 6 emoji'));
    await _settle(tester);

    _expectUnder(
      tester,
      'Not a PNG, JPEG, GIF or WEBP image.',
      'text_as.png',
      'huge.png',
    );
    _expectUnder(
      tester,
      'Larger than 1024 pixels on a side.',
      'huge.png',
      'eee.png',
    );
    expect(find.text('2 images need fixing.'), findsOneWidget);
    expect(
      find.textContaining('could not be added'),
      findsNothing,
      reason: 'each row already says why',
    );
    expect(_disabled(tester, 'Create 6 emoji'), isTrue);

    await tester.enterText(_field('huge.png'), 'huge_two');
    await _settle(tester);
    expect(
      find.text('Larger than 1024 pixels on a side.'),
      findsOneWidget,
      reason: 'a new name does not make the image smaller',
    );

    for (final bad in ['text_as.png', 'huge.png']) {
      await tester.tap(find.byKey(ValueKey('emoji-remove-$bad')));
      await _settle(tester);
    }
    expect(_disabled(tester, 'Create 4 emoji'), isFalse);

    await tester.tap(find.text('Create 4 emoji'));
    await _settle(tester);
    expect(bulkNames(h.bulks.last), ['aaa', 'bbb', 'eee', 'fff']);
    expect(find.textContaining('Added 4 of 4'), findsOneWidget);
  });

  testWidgets('a refusal about the whole batch stays in the summary, not on a '
      'row', (tester) async {
    final h = EmojiHarness(
      picks: [emojiPick('aaa.png'), emojiPick('bbb.png')],
      onBulk: (r) => emojiJson({
        'error': 'image 1 (aaa): this deployment is at its emoji limit',
        'item_index': 0,
        'item_code': 'full',
      }, status: 409),
    );
    await h.pump(tester);
    await h.choose(tester);

    await tester.tap(find.text('Create 2 emoji'));
    await _settle(tester);

    expect(find.textContaining('need fixing'), findsNothing);
    expect(find.textContaining('at its emoji limit'), findsOneWidget);
    expect(_disabled(tester, 'Create 2 emoji'), isFalse);
  });
}
