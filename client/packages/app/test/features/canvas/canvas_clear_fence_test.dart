// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Clear is fenced on the server's head, so it still works for an admin whose
/// viewport read failed instead of silently clearing nothing.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/permissions.dart';

import 'canvas_pane_harness.dart';

void main() {
  testWidgets('Clear fences on the current head when the viewport never loaded', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture(
      mePermissions: Perm.manageCanvas,
      viewportStatus: 500,
    )..opsHead = 7;
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);
    await tester.pump();

    await tester.tap(find.bySemanticsLabel('More canvas actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear canvas'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear canvas').last);
    await tester.pumpAndSettle();

    expect(fixture.postedOps, hasLength(1));
    expect(fixture.postedOps.single['kind'], 'clear');
    expect(fixture.postedOps.single['before_seq'], 7);
    await tester.pumpWidget(const SizedBox());
  });
}
