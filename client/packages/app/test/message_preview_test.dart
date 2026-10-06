// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A quote of a message shows its text, never the markdown that formats it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/message_preview.dart';
import 'package:slimm_app/src/widgets/reply_banner.dart';
import 'package:slimm_app/src/widgets/reply_quote.dart';

import 'message_row_harness.dart';

const _fenced =
    'Here is the snippet I mean:\n```dart\nclass Rail extends StatelessWidget {}\n```';

void main() {
  group('plainPreview', () {
    test('collapses a fenced block to a code marker', () {
      expect(plainPreview(_fenced), 'Here is the snippet I mean: [code]');
    });

    test('a message that opens with a fence reads as code', () {
      expect(
        plainPreview('```\nlet x = 1;\n```\nthen this'),
        '[code] then this',
      );
    });

    test('an unterminated fence does not leak its backticks', () {
      expect(plainPreview('look:\n```dart\nclass A {'), 'look: [code]');
    });

    test('inline code keeps its text and loses its backticks', () {
      expect(plainPreview('run `make test` now'), 'run make test now');
    });

    test('plain text is only flattened to one line', () {
      expect(plainPreview('one\ntwo  three'), 'one two three');
    });

    test('a spoiler reads as a placeholder, never its text', () {
      expect(
        plainPreview('plot twist ||the butler did it||'),
        'plot twist $spoilerPlaceholder',
      );
    });

    test('a spoiler with formatting inside it still hides it all', () {
      expect(
        plainPreview('||**the** butler|| and ||~~more~~||'),
        '$spoilerPlaceholder and $spoilerPlaceholder',
      );
    });

    test('bold, italic and strikethrough lose their markers', () {
      expect(plainPreview('**bold** *italic* ~~gone~~'), 'bold italic gone');
    });

    test('bars inside inline code are literal text, not a spoiler', () {
      expect(plainPreview('use `a || b` here'), 'use a || b here');
    });

    test('a lone pair of bars with nothing closing it stays as typed', () {
      expect(plainPreview('a || b'), 'a || b');
    });

    test('mentions and links are kept as written', () {
      expect(
        plainPreview('hi @nick see https://example.com/x'),
        'hi @nick see https://example.com/x',
      );
    });
  });

  testWidgets('a reply quote of a fenced message shows no backticks', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(
        ReplyQuote(
          resolved: message(
            id: 'parent',
            authorId: 'priya',
            authorDisplayName: 'Priya',
            content: _fenced,
          ),
          onTap: () {},
        ),
      ),
    );

    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
        .join(' ');
    expect(texts, contains('Here is the snippet I mean: [code]'));
    expect(texts, isNot(contains('`')));
  });

  testWidgets('a reply quote hides what is under a spoiler', (tester) async {
    await tester.pumpWidget(
      harness(
        ReplyQuote(
          resolved: message(content: 'plot twist ||the butler did it||'),
          onTap: () {},
        ),
      ),
    );

    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
        .join(' ');
    expect(texts, isNot(contains('butler')));
    expect(texts, contains(spoilerPlaceholder));
  });

  testWidgets('the reply banner hides it too', (tester) async {
    await tester.pumpWidget(
      harness(
        ReplyBanner(
          message: message(content: 'plot twist ||the butler did it||'),
          onCancel: () {},
        ),
      ),
    );

    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
        .join(' ');
    expect(texts, isNot(contains('butler')));
    expect(texts, contains(spoilerPlaceholder));
  });
}
