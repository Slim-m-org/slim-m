// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Widget tests for [MessageBody]'s new markdown rendering: inline styling,
/// spoilers, headings, quotes and lists, on top of the fenced-code and
/// mention/emoji handling `message_text_test.dart` already covers.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_markdown_blocks.dart';
import 'package:slimm_app/src/features/messages/widgets/message_spoiler.dart';
import 'package:slimm_app/src/features/messages/widgets/message_text.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _harness(Widget child) => MaterialApp(
  theme: buildTheme(Brightness.light, AppTokens.light),
  home: Scaffold(body: child),
);

/// The [index]th `_MessageTextRun`'s own span tree, unwrapped past the extra
/// layer `Text.rich` adds: `Text.build()` wraps whatever span it is given in
/// `TextSpan(style: mergedStyle, children: [ourSpan])`, so `ourSpan` (what
/// `message_text.dart` actually built) is one level of `.children!.single`
/// deeper than the `RichText` widget's own `.text`.
TextSpan _messageSpan(WidgetTester tester, {int index = 0}) {
  final richTexts = tester
      .widgetList<RichText>(
        find.descendant(
          of: find.byType(MessageBody),
          matching: find.byType(RichText),
        ),
      )
      .toList();
  final outer = richTexts[index].text as TextSpan;
  return outer.children!.single as TextSpan;
}

void main() {
  testWidgets('bold renders with the semi weight', (tester) async {
    await tester.pumpWidget(
      _harness(const MessageBody(content: '**bold**', knownUsernames: {})),
    );
    final child = _messageSpan(tester).children!.single as TextSpan;
    expect(child.style!.fontWeight, AppWeights.semi);
    expect(child.toPlainText(), 'bold');
  });

  testWidgets('italic renders with an italic font style', (tester) async {
    await tester.pumpWidget(
      _harness(const MessageBody(content: '*italic*', knownUsernames: {})),
    );
    final child = _messageSpan(tester).children!.single as TextSpan;
    expect(child.style!.fontStyle, FontStyle.italic);
  });

  testWidgets('strikethrough renders with a line-through decoration', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(const MessageBody(content: '~~gone~~', knownUsernames: {})),
    );
    final child = _messageSpan(tester).children!.single as TextSpan;
    expect(child.style!.decoration, TextDecoration.lineThrough);
  });

  testWidgets('a spoiler hides its text behind a bar until tapped', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        const MessageBody(content: 'it was ||him||', knownUsernames: {}),
      ),
    );

    expect(find.byType(MessageSpoiler), findsOneWidget);
    // The text is present but invisible; the bar is what proves it is hidden.
    expect(
      find.descendant(
        of: find.byType(MessageSpoiler),
        matching: find.byType(DecoratedBox),
      ),
      findsOneWidget,
    );
    final hiddenOpacity = tester.widget<Opacity>(
      find.descendant(
        of: find.byType(MessageSpoiler),
        matching: find.byType(Opacity),
      ),
    );
    expect(hiddenOpacity.opacity, 0);

    await tester.tap(find.byType(MessageSpoiler));
    await tester.pump();

    expect(
      find.descendant(
        of: find.byType(MessageSpoiler),
        matching: find.byType(DecoratedBox),
      ),
      findsNothing,
    );
    final revealedOpacity = tester.widget<Opacity>(
      find.descendant(
        of: find.byType(MessageSpoiler),
        matching: find.byType(Opacity),
      ),
    );
    expect(revealedOpacity.opacity, 1);
  });

  testWidgets('tapping a revealed spoiler hides it again', (tester) async {
    await tester.pumpWidget(
      _harness(const MessageBody(content: '||toggle||', knownUsernames: {})),
    );
    await tester.tap(find.byType(MessageSpoiler));
    await tester.pump();
    expect(
      find.descendant(
        of: find.byType(MessageSpoiler),
        matching: find.byType(DecoratedBox),
      ),
      findsNothing,
    );

    await tester.tap(find.byType(MessageSpoiler));
    await tester.pump();
    expect(
      find.descendant(
        of: find.byType(MessageSpoiler),
        matching: find.byType(DecoratedBox),
      ),
      findsOneWidget,
    );
  });

  group('a spoiler is reachable and revealable from the keyboard', () {
    setUp(() {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
    });
    tearDown(() {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic;
    });

    testWidgets('Tab lands on it and Enter reveals it', (tester) async {
      await tester.pumpWidget(
        _harness(
          const MessageBody(content: 'it was ||him||', knownUsernames: {}),
        ),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(MessageSpoiler),
          matching: find.byWidgetPredicate(
            (w) =>
                w is DecoratedBox &&
                (w.decoration as BoxDecoration).border?.top.color ==
                    AppTokens.light.focusRing,
          ),
        ),
        findsOneWidget,
        reason:
            'a spoiler a keyboard cannot land on has no route to revealing '
            'it, and one that takes focus silently is a route nobody can see',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(
        find.descendant(
          of: find.byType(MessageSpoiler),
          matching: find.byWidgetPredicate(
            (w) =>
                w is DecoratedBox &&
                (w.decoration as BoxDecoration).color ==
                    AppTokens.light.textPrimary,
          ),
        ),
        findsNothing,
        reason: 'the hiding bar is gone once revealed',
      );
    });

    testWidgets('Space also reveals it', (tester) async {
      await tester.pumpWidget(
        _harness(
          const MessageBody(content: 'it was ||him||', knownUsernames: {}),
        ),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();

      final opacity = tester.widget<Opacity>(
        find.descendant(
          of: find.byType(MessageSpoiler),
          matching: find.byType(Opacity),
        ),
      );
      expect(opacity.opacity, 1);
    });
  });

  testWidgets('a heading renders at a larger type size than a paragraph', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        const MessageBody(
          content: '# Big\n\nordinary text',
          knownUsernames: {},
        ),
      ),
    );

    final headingStyle = _messageSpan(tester, index: 0).style!;
    expect(headingStyle.fontSize, AppText.title.fontSize);
    expect(headingStyle.fontWeight, AppWeights.semi);
  });

  testWidgets('a quote renders inside MarkdownQuote with a left rule', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(const MessageBody(content: '> quoted text', knownUsernames: {})),
    );
    expect(find.byType(MarkdownQuote), findsOneWidget);
    expect(find.textContaining('quoted text'), findsOneWidget);
  });

  testWidgets('a bullet list renders through MarkdownList with both items', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        const MessageBody(content: '- first\n- second', knownUsernames: {}),
      ),
    );
    expect(find.byType(MarkdownList), findsOneWidget);
    expect(find.textContaining('first'), findsOneWidget);
    expect(find.textContaining('second'), findsOneWidget);
  });

  testWidgets('mentions and inline code still work inside a plain paragraph '
      'alongside the new inline parser', (tester) async {
    await tester.pumpWidget(
      _harness(
        const MessageBody(
          content: 'hey @nick, run `flutter test`',
          knownUsernames: {'nick'},
        ),
      ),
    );
    expect(find.text('@nick'), findsOneWidget);
    expect(find.text('flutter test'), findsOneWidget);
  });

  testWidgets('a mention still resolves correctly when it sits inside bold '
      'text', (tester) async {
    await tester.pumpWidget(
      _harness(
        const MessageBody(content: '**@nick**', knownUsernames: {'nick'}),
      ),
    );
    expect(find.text('@nick'), findsOneWidget);
  });

  testWidgets('a three-level numbered list indents each level and restarts '
      'its numbers', (tester) async {
    await tester.pumpWidget(
      _harness(
        const MessageBody(
          content: '1. a\n  1. b\n    1. c\n    2. d\n  2. e\n2. f',
          knownUsernames: {},
        ),
      ),
    );
    expect(find.byType(MarkdownList), findsOneWidget);
    double left(String text) => tester.getTopLeft(find.text(text)).dx;
    expect(left('b'), greaterThan(left('a')));
    expect(left('c'), greaterThan(left('b')));
    expect(left('d'), left('c'));
    expect(left('e'), left('b'));
    expect(left('f'), left('a'));
    final markers = find.descendant(
      of: find.byType(MarkdownList),
      matching: find.textContaining(RegExp(r'^\d\.$')),
    );
    expect(tester.widgetList<Text>(markers).map((t) => t.data), [
      '1.',
      '1.',
      '1.',
      '2.',
      '2.',
      '2.',
    ]);
  });

  testWidgets('bullets take a distinct glyph at each of three levels', (
    tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        const MessageBody(content: '- a\n  - b\n    - c', knownUsernames: {}),
      ),
    );
    for (final glyph in ['•', '–', '◦']) {
      expect(find.text(glyph), findsOneWidget);
    }
  });
}
