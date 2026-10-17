// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether the floating dock's own hit test actually matches its two
/// stated guarantees: a right-click anywhere on the card is absorbed, and a
/// primary-button gesture on the card's own background (padding, the
/// inter-row divider, any strip slack - never an actual button) still
/// reaches `CanvasSurface` beneath it rather than being silently swallowed
/// alongside the right-click. `floating_dock_card.dart`'s own library doc
/// explains why `HitTestBehavior.translucent` is what makes both true at
/// once, rather than the `opaque` an earlier draft used.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/floating_dock_card.dart';

import 'features/canvas/canvas_pane_harness.dart';

void main() {
  testWidgets(
    'a pen drag started on the dock\'s own padding draws, same as one just above it',
    (tester) async {
      final fixture = CanvasPaneFixture();
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);
      await pumpCanvasPane(tester, container);

      final cardRect = tester.getRect(find.byType(FloatingDockCard));
      // A few pixels inside the card's top-left corner: its own padding, not a button.
      final onPadding = cardRect.topLeft + const Offset(3, 3);

      final onCard = await tester.startGesture(onPadding);
      await onCard.moveTo(onPadding + const Offset(20, 0));
      await onCard.up();
      await tester.pump();
      await tester.pumpAndSettle();

      expect(
        fixture.posted,
        hasLength(1),
        reason:
            'the dock only absorbs a right-click, never a primary drag '
            'that starts on its own background',
      );
    },
  );

  testWidgets(
    'a right-click on the dock\'s own padding is absorbed, never reaching a canvas object underneath it',
    (tester) async {
      final fixture = CanvasPaneFixture()
        // A huge note spanning the whole visible world, so the click below always lands on it.
        ..objects = [
          {
            'id': 'under-the-dock',
            'kind': 'note',
            'z_index': 1,
            'x': -5000.0,
            'y': -5000.0,
            'w': 10000.0,
            'h': 10000.0,
            'props': {'text': 'covers everything'},
            'author_id': 'me',
            'seq': 1,
            'created_at': 0,
          },
        ];
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);
      await pumpCanvasPane(tester, container);
      await tester.pumpAndSettle();

      final cardRect = tester.getRect(find.byType(FloatingDockCard));
      final onPadding = cardRect.topLeft + const Offset(3, 3);
      await tester.tapAt(onPadding, buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      expect(find.text('Send to back'), findsNothing);
    },
  );
}
