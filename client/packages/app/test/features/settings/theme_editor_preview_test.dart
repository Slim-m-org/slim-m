// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The editor's pinned preview: what repaints while a colour changes, and how
/// it folds to a short strip as the column scrolls under it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

import 'theme_editor_harness.dart';
import 'theme_gallery_rig.dart' show stored;

Color? _linkColour(WidgetTester tester) => tester
    .widget<Text>(
      find.descendant(
        of: byKey('theme-editor-preview'),
        matching: find.text('Link to the build'),
      ),
    )
    .style!
    .color;

Finder _inPreview(String text) => find.descendant(
  of: byKey('theme-editor-preview'),
  matching: find.text(text),
);

Future<void> _scrollTo(WidgetTester tester, double offset) async {
  final scrollable = find
      .descendant(
        of: byKey('theme-editor-tokens'),
        matching: find.byWidgetPredicate((w) => w is Scrollable),
      )
      .first;
  tester.state<ScrollableState>(scrollable).position.jumpTo(offset);
  await tester.pump();
}

void main() {
  testWidgets('at a laptop the second message and the samples fold away as '
      'the column scrolls, and come back at the top', (tester) async {
    await EditorRig().open(tester);
    final full = tester.getRect(byKey('theme-editor-preview'));
    expect(_inPreview('Focused control'), findsOneWidget);
    expect(byKey('theme-editor-preview-fade'), findsNothing);

    await _scrollTo(tester, 400);
    final folded = tester.getRect(byKey('theme-editor-preview'));
    expect(folded.height, lessThan(full.height * 0.6));
    expect(_inPreview('Focused control'), findsNothing);
    expect(_inPreview('Reads well. The links are a bit dim.'), findsNothing);
    expect(_inPreview('Link to the build'), findsOneWidget);
    expect(_inPreview('Message #general'), findsOneWidget);
    expect(byKey('theme-editor-preview-fade'), findsOneWidget);

    await _scrollTo(tester, 0);
    expect(tester.getRect(byKey('theme-editor-preview')), full);
    expect(byKey('theme-editor-preview-fade'), findsNothing);
  });

  testWidgets('on a phone the link line folds away, leaving the message and '
      'the composer', (tester) async {
    await EditorRig().open(tester, size: phone);
    expect(_inPreview('Link to the build'), findsOneWidget);

    await _scrollTo(tester, 400);
    expect(_inPreview('Link to the build'), findsNothing);
    expect(
      _inPreview('Pine at dusk is up. Have a look at the new theme.'),
      findsOneWidget,
    );
    expect(_inPreview('Message #general'), findsOneWidget);
  });

  for (final (name, size) in [('laptop', laptop), ('phone', phone)]) {
    testWidgets('on a $name the column follows the finger while the preview '
        'folds', (tester) async {
      await EditorRig().open(tester, size: size);
      final preview = tester.getRect(byKey('theme-editor-preview'));
      final details = tester.getRect(byKey('theme-editor-details'));

      await _scrollTo(tester, 24);

      final folding = tester.getRect(byKey('theme-editor-preview'));
      expect(folding.height, closeTo(preview.height - 24, 0.5));
      expect(
        tester.getRect(byKey('theme-editor-details')).top,
        closeTo(details.top - 24, 0.5),
      );
    });
  }

  testWidgets('a colour change repaints the preview, not the header or '
      'Details', (tester) async {
    final rig = EditorRig(storeThemes: [stored('t1', 'Pine', author: 'ren')]);
    await rig.open(tester);
    await tapIn(tester, byKey('theme-main-accent'));
    final hex = find.byKey(AppColourPicker.hexFieldKey);
    await tester.enterText(hex, '40A0D0');
    await settle(tester);
    final menu = tester.widget(byKey('theme-editor-menu'));
    final startFrom = tester.widget(byKey('theme-editor-start-from'));
    final before = _linkColour(tester);

    await tester.enterText(hex, 'D04040');
    await tester.pump();

    expect(_linkColour(tester), isNot(before));
    expect(identical(tester.widget(byKey('theme-editor-menu')), menu), isTrue);
    expect(
      identical(tester.widget(byKey('theme-editor-start-from')), startFrom),
      isTrue,
    );
  });
}
