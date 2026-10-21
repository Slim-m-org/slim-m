// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The dock's more-actions button opens its menu and a second press closes it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/canvas_tools_row_fixtures.dart';

void main() {
  testWidgets('a second press on the more button closes its menu', (
    tester,
  ) async {
    await tester.pumpWidget(wrapCanvasToolsRow(buildCanvasToolsRow()));
    await tester.tap(find.bySemanticsLabel('More canvas actions'));
    await tester.pumpAndSettle();
    expect(find.byType(AppMenu), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('More canvas actions'));
    await tester.pumpAndSettle();
    expect(find.byType(AppMenu), findsNothing);
  });
}
