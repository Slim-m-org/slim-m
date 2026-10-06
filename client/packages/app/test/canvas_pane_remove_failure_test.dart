// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Deleting an object the server then refuses to remove: the pane shows the
/// error and the object comes back, rather than staying hidden here while it
/// still exists for everyone else.
library;

import 'package:flutter_test/flutter_test.dart';

import 'canvas_pane_harness.dart';

void main() {
  testWidgets('a refused delete shows the error and the object returns', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture(opsPostStatus: 403)
      ..objects = [canvasNoteJson('note')];
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);
    await tester.pumpAndSettle();
    expect(surfaceDocument(tester).objectCount.value, 1);
    final readsBefore = fixture.viewportGets;

    await tester.tap(find.bySemanticsLabel('Pan'));
    await tester.pump();
    final tap = await tester.startGesture(
      screenFor(tester, const Offset(15, 15)),
    );
    await tap.up();
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('More canvas actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.text('That could not be deleted.'), findsOneWidget);
    expect(fixture.viewportGets, greaterThan(readsBefore));
    expect(
      surfaceDocument(tester).objectCount.value,
      1,
      reason: 'the refused delete must not leave the note gone locally',
    );
  });
}
