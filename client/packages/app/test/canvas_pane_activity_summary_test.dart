// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The activity panel's own summary line must track the live document
/// while the panel stays open, not just refresh on the next open/close
/// toggle - a real bug this caught: `CanvasPaneBody`'s panel branch first
/// read `document.objectCount` nowhere at all, and this pane never
/// rebuilds on its own when the document changes, by design (see
/// `canvas_pane.dart`'s own doc comment on staying off the render loop).
/// A local draw cannot exercise this: it needs the surface, which the
/// panel replaces, so this drives a live frame from another participant
/// instead - the scenario the bug actually mattered for.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;

import 'features/canvas/canvas_pane_harness.dart';

void main() {
  testWidgets(
    "a live placement from another participant updates the panel's summary "
    'while it stays open, with no toggle in between',
    (tester) async {
      final fixture = CanvasPaneFixture();
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);
      await pumpCanvasPane(tester, container);

      await tester.tap(find.bySemanticsLabel('More canvas actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show activity log'));
      await tester.pumpAndSettle();

      expect(find.text('no objects'), findsOneWidget);

      fixture.events.add(
        api.CanvasObjectPlaced(
          channelId: 'c1',
          object: api.CanvasObject.fromJson(
            canvasObjectJson('remote-stroke', authorId: 'someone-else'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        find.text(
          '1 object: 1 stroke, 0 images, 0 notes, 0 shapes, 0 text boxes',
        ),
        findsOneWidget,
        reason:
            'the panel was never closed and reopened, so this only '
            'passes if the summary itself listens for the change',
      );
    },
  );
}
