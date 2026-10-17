// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rail, DM and member rows all wrap an `AppListRow` in a
/// `ContextMenuRegion`; a phone long press on one must leave the row at rest
/// whichever way the sheet it opens is dismissed.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/context_menu_region.dart';
import 'package:slimm_design_system/design_system.dart';

import 'features/messages/message_row_harness.dart';

Widget _row() => harness(
  ContextMenuRegion(
    itemsBuilder: (context, close) => [
      AppMenuItem(label: 'Mute channel', onTap: close),
    ],
    child: SizedBox(
      height: 44,
      child: AppListRow(label: 'general', onTap: () {}),
    ),
  ),
);

Color? _fill(WidgetTester tester) {
  final decoration = tester
      .widgetList<AnimatedContainer>(
        find.descendant(
          of: find.byType(AppListRow),
          matching: find.byType(AnimatedContainer),
        ),
      )
      .firstWhere((c) => c.decoration is BoxDecoration)
      .decoration;
  return (decoration as BoxDecoration?)?.color;
}

Future<void> _longPressRow(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_row());
  await tester.pumpAndSettle();
  await tester.longPress(find.byType(AppListRow));
  await tester.pumpAndSettle();
  expect(find.text('Mute channel'), findsOneWidget);
}

void main() {
  testWidgets('scrim tap after a long press leaves the row at rest', (
    tester,
  ) async {
    await _longPressRow(tester);
    await tester.tapAt(const Offset(195, 300));
    await tester.pumpAndSettle();

    expect(find.text('Mute channel'), findsNothing);
    expect(_fill(tester), Colors.transparent);
  });

  testWidgets('choosing an item after a long press leaves the row at rest', (
    tester,
  ) async {
    await _longPressRow(tester);
    await tester.tap(find.text('Mute channel'));
    await tester.pumpAndSettle();

    expect(find.text('Mute channel'), findsNothing);
    expect(_fill(tester), Colors.transparent);
  });
}
