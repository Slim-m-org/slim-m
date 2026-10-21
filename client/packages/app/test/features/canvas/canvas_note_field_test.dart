// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The note text box carries the composer's input features, and the painter's
/// spans show a note's markdown and mentions.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/widgets/canvas_note_field.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_note_limits.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_note_spans.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart'
    show membersProvider;
import 'package:slimm_design_system/design_system.dart';

const _alice = api.UserProfile(
  id: 'u-alice',
  username: 'alice',
  displayName: 'Alice Park',
  createdAt: 0,
);

Future<TextEditingController> _pump(WidgetTester tester) async {
  final controller = TextEditingController();
  final focus = FocusNode();
  addTearDown(controller.dispose);
  addTearDown(focus.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        membersProvider.overrideWith((ref) async => const [_alice]),
        customEmojiProvider.overrideWith((ref) async => const []),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: CanvasNoteField(controller: controller, focusNode: focus),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  focus.requestFocus();
  await tester.pump();
  return controller;
}

void main() {
  testWidgets('typing @ offers members by display name and username', (
    tester,
  ) async {
    final controller = await _pump(tester);

    await tester.enterText(find.byType(TextField), 'hi @al');
    await tester.pumpAndSettle();

    expect(find.text('Alice Park'), findsOneWidget);
    expect(find.text('@alice'), findsOneWidget);

    await tester.tap(find.text('Alice Park'));
    await tester.pump();
    expect(controller.text, 'hi @alice ');
  });

  testWidgets('Tab takes the highlighted mention', (tester) async {
    final controller = await _pump(tester);

    await tester.enterText(find.byType(TextField), '@al');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(controller.text, '@alice ');
  });

  testWidgets('Enter on a list line continues the list', (tester) async {
    final controller = await _pump(tester);

    await tester.enterText(find.byType(TextField), '- one');
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(controller.text, '- one\n- ');
  });

  testWidgets('Ctrl+B wraps the selection in bold markers', (tester) async {
    final controller = await _pump(tester);

    await tester.enterText(find.byType(TextField), 'word');
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 4);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(controller.text, '**word**');
  });

  testWidgets('a completed :shortcode: becomes its emoji', (tester) async {
    final controller = await _pump(tester);

    await tester.enterText(find.byType(TextField), ':fire');
    await tester.pump();
    await tester.enterText(find.byType(TextField), ':fire:');
    await tester.pump();

    expect(controller.text, isNot(':fire:'));
  });

  group('note spans', () {
    const style = NoteSpanStyle(
      knownUsernames: {'alice'},
      mentionInk: Color(0xFF111111),
      mentionFill: Color(0xFF222222),
      linkInk: Color(0xFF333333),
    );

    /// Each text run with the style it is finally drawn in.
    List<({String text, TextStyle style})> flat(
      InlineSpan span, [
      TextStyle inherited = const TextStyle(),
    ]) {
      if (span is! TextSpan) return const [];
      final style = inherited.merge(span.style);
      return [
        if (span.text != null) (text: span.text!, style: style),
        for (final child in span.children ?? const <InlineSpan>[])
          ...flat(child, style),
      ];
    }

    test('bold and italic come out as weight and slant', () {
      final spans = flat(
        buildNoteSpans('a **b** *c*', const TextStyle(), style),
      );

      final bold = spans.firstWhere((s) => s.text == 'b');
      expect(bold.style.fontWeight, AppWeights.semi);
      final italic = spans.firstWhere((s) => s.text == 'c');
      expect(italic.style.fontStyle, FontStyle.italic);
    });

    test('a known mention is a chip and an unknown one stays plain', () {
      final spans = flat(
        buildNoteSpans('@alice and @nobody', const TextStyle(), style),
      );

      final known = spans.firstWhere((s) => s.text == '@alice');
      expect(known.style.backgroundColor, style.mentionFill);
      expect(known.style.color, style.mentionInk);
      final unknown = spans.firstWhere((s) => s.text == '@nobody');
      expect(unknown.style.backgroundColor, isNull);
    });

    test('a link is underlined in the link colour', () {
      final spans = flat(
        buildNoteSpans('see https://example.com', const TextStyle(), style),
      );

      final link = spans.firstWhere((s) => s.text == 'https://example.com');
      expect(link.style.decoration, TextDecoration.underline);
      expect(link.style.color, style.linkInk);
    });
  });

  testWidgets('Enter while an IME composition is open leaves the text alone', (
    tester,
  ) async {
    final controller = await _pump(tester);

    controller.value = const TextEditingValue(
      text: '- ni',
      selection: TextSelection.collapsed(offset: 4),
      composing: TextRange(start: 2, end: 4),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(controller.text, '- ni');
  });

  testWidgets('Enter on a full note adds nothing and says the note is full', (
    tester,
  ) async {
    final controller = await _pump(tester);
    // Fits with its list marker; the continued marker on Enter would not.
    final full = 'a' * (maxNoteTextBytes - 14);
    controller.value = TextEditingValue(
      text: '- $full',
      selection: TextSelection.collapsed(offset: full.length + 2),
    );
    await tester.pump();
    expect(find.text('This note is full.'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(controller.text, '- $full');
    expect(find.text('This note is full.'), findsOneWidget);
  });

  testWidgets('typing past the limit is refused and says so', (tester) async {
    final controller = await _pump(tester);
    controller.text = 'a' * (maxNoteTextBytes - 20);
    await tester.pump();
    await tester.enterText(
      find.byType(TextField),
      'b' * (maxNoteTextBytes + 10),
    );
    await tester.pump();

    expect(noteWireBytes(controller.text), lessThanOrEqualTo(maxNoteTextBytes));
    expect(find.text('This note is full.'), findsOneWidget);
  });
}
