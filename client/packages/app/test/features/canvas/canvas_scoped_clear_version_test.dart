// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Scoped/partial clear is gated on the server version advertised on `/version`.
/// An older deployment (< 0.98.0) cannot handle `clear_scoped` ops, so the action
/// is omitted from the menu rather than failing when tapped.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/permissions.dart';

import 'canvas_pane_harness.dart';

void main() {
  testWidgets(
    'Clear part of the canvas is offered when server is at or above 0.98.0',
    (tester) async {
      final fixture = CanvasPaneFixture(mePermissions: Perm.manageCanvas)
        ..serverVersion = '0.102.0';
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);

      await pumpCanvasPane(tester, container);
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel('More canvas actions'));
      await tester.pumpAndSettle();

      expect(find.text('Clear canvas'), findsOneWidget);
      expect(find.text('Clear part of the canvas'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Clear part of the canvas is hidden when server is below 0.98.0',
    (tester) async {
      final fixture = CanvasPaneFixture(mePermissions: Perm.manageCanvas)
        ..serverVersion = '0.92.0';
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);

      await pumpCanvasPane(tester, container);
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel('More canvas actions'));
      await tester.pumpAndSettle();

      expect(find.text('Clear canvas'), findsOneWidget);
      expect(find.text('Clear part of the canvas'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
