// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The text activity log is a screen reader's fallback for the drawing, so a
/// sighted viewer's menu does not carry it and the board offers it to a reader,
/// by a custom action and by a key that needs no platform to report one.
library;

import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'canvas_pane_harness.dart';

const _show = CustomSemanticsAction(label: 'Show activity log');

void main() {
  testWidgets("a sighted viewer's overflow has no activity log", (
    tester,
  ) async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);

    await tester.tap(find.bySemanticsLabel('More canvas actions'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Snap to grid'), findsOneWidget);
    expect(find.text('Show activity log'), findsNothing);
  });

  testWidgets('the board offers a screen reader the activity log', (
    tester,
  ) async {
    final fixture = CanvasPaneFixture();
    final container = fixture.container();
    addTearDown(container.dispose);
    addTearDown(fixture.events.close);
    await pumpCanvasPane(tester, container);

    final board = tester.getSemantics(
      find.bySemanticsLabel(RegExp(r'^Canvas, ')),
    );
    final id = CustomSemanticsAction.getIdentifier(_show);
    expect(board.getSemanticsData().customSemanticsActionIds, contains(id));

    board.owner!.performAction(board.id, SemanticsAction.customAction, id);
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('no objects'), findsOneWidget);
  });

  testWidgets(
    'with no screen reader reported, L on the board opens the log, and the '
    "board's hint names the key",
    (tester) async {
      final fixture = CanvasPaneFixture();
      final container = fixture.container();
      addTearDown(container.dispose);
      addTearDown(fixture.events.close);
      await pumpCanvasPane(tester, container);
      expect(
        tester
            .binding
            .platformDispatcher
            .accessibilityFeatures
            .accessibleNavigation,
        isFalse,
      );

      final board = tester.getSemantics(find.bySemanticsLabel('Canvas board'));
      expect(
        board.getSemanticsData().hint,
        contains('L opens the activity log'),
      );
      expect(find.text('no objects'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('no objects'), findsOneWidget);
    },
  );
}
