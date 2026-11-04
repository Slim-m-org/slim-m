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
}
