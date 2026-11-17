// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [AppSheetHeader] is the one title row sheets open with.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _pump(WidgetTester tester, Widget header) => tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(body: SizedBox(width: 360, child: header)),
      ),
    );

void main() {
  testWidgets('title is a header and sits left-aligned', (tester) async {
    await _pump(tester, const AppSheetHeader('Forward message'));

    expect(find.text('Forward message'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Forward message')).dx, 16);
    expect(
      tester
          .getSemantics(find.text('Forward message'))
          .flagsCollection
          .isHeader,
      isTrue,
    );
  });

  testWidgets('the title is a semibold heading, as a confirm sheet\'s is', (
    tester,
  ) async {
    await _pump(tester, const AppSheetHeader('Forward message'));

    final style = tester.widget<Text>(find.text('Forward message')).style!;
    expect(style.fontSize, AppText.heading.fontSize);
    expect(style.fontWeight, AppWeights.semi);
  });

  testWidgets('caption sits under the title', (tester) async {
    await _pump(
      tester,
      const AppSheetHeader('Crop', caption: 'Drag to move.'),
    );

    expect(
      tester.getTopLeft(find.text('Drag to move.')).dy,
      greaterThan(tester.getBottomLeft(find.text('Crop')).dy),
    );
  });

  testWidgets('trailing sits at the end of the row', (tester) async {
    await _pump(
      tester,
      const AppSheetHeader('Inbox', trailing: Text('Mark all read')),
    );

    expect(
      tester.getTopRight(find.text('Mark all read')).dx,
      lessThanOrEqualTo(360 - 16),
    );
    expect(
      tester.getTopLeft(find.text('Mark all read')).dx,
      greaterThan(tester.getTopRight(find.text('Inbox')).dx),
    );
  });

  testWidgets('leading sits before the title, centred on the text', (
    tester,
  ) async {
    await _pump(
      tester,
      const AppSheetHeader(
        'Midnight',
        caption: 'Space · by Kai',
        leading: SizedBox(key: Key('thumb'), width: 48, height: 30),
      ),
    );

    final thumb = tester.getRect(find.byKey(const Key('thumb')));
    final title = tester.getRect(find.text('Midnight'));
    final caption = tester.getRect(find.text('Space · by Kai'));
    expect(thumb.left, 16);
    expect(title.left, thumb.right + 12);
    expect(caption.left, title.left);
    final textMid = (title.top + caption.bottom) / 2;
    expect((thumb.center.dy - textMid).abs(), lessThan(1));
  });
}
