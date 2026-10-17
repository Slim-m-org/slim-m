// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Decision 0047's layout rules, asserted as geometry: the dock hugs its
/// content, leave is the last control after a divider, the canvas button is
/// one toggle, and the phone stack keeps its order and 44dp targets.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/widgets/call_dock_button.dart';
import 'package:slimm_app/src/widgets/floating_dock_card.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/canvas_call_dock_fixtures.dart';

const _windowWidth = 2000.0;

void _sizeWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(_windowWidth, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Rect _card(WidgetTester tester) =>
    tester.getRect(find.byType(FloatingDockCard));

Finder _leave() => find.byWidgetPredicate(
  (w) => w is CallDockButton && w.tooltip.startsWith('Leave call'),
);

List<Rect> _controlRects(WidgetTester tester) => [
  for (final e in find.byType(CallDockButton).evaluate())
    tester.getRect(find.byWidget(e.widget)),
  for (final e in find.byType(AppIconButton).evaluate())
    tester.getRect(find.byWidget(e.widget)),
];

void main() {
  testWidgets('with the canvas open the dock hugs its content and stays '
      'centred, instead of stretching to a wide pane', (tester) async {
    _sizeWindow(tester);
    await pumpCanvasCallDock(tester, withCall: true, width: 1500, hug: true);
    final callOnly = _card(tester).width;

    await pumpCanvasCallDock(
      tester,
      withCall: true,
      canvas: buildCanvasDockData(),
      width: 1500,
      hug: true,
    );
    final card = _card(tester);

    expect(card.width, greaterThan(callOnly));
    expect(card.width, lessThan(900), reason: 'a pane is 1500 wide');
    expect(card.center.dx, closeTo(_windowWidth / 2, 1));
    expect(
      card.right - tester.getRect(_leave()).right,
      lessThan(AppSpacing.s12 + AppSpacing.s8),
      reason: 'leave sits at the hugged edge, not pinned to the pane',
    );
  });

  for (final withCanvas in [false, true]) {
    testWidgets(
      'leave is the last control, after a divider, and the only danger '
      'control (canvas ${withCanvas ? 'open' : 'closed'})',
      (tester) async {
        _sizeWindow(tester);
        await pumpCanvasCallDock(
          tester,
          withCall: true,
          canvas: withCanvas ? buildCanvasDockData() : null,
          width: 1500,
          hug: true,
        );

        final leave = tester.getRect(_leave());
        for (final other in _controlRects(tester)) {
          if (other == leave) continue;
          expect(other.center.dx, lessThan(leave.center.dx));
        }
        final divider = tester.getRect(find.byType(DockVerticalDivider).last);
        expect(divider.width, 1);
        expect(divider.height, AppSpacing.s24);
        expect(divider.right, lessThanOrEqualTo(leave.left));
        final destructive = tester
            .widgetList<CallDockButton>(find.byType(CallDockButton))
            .where((b) => b.destructive);
        expect(destructive, hasLength(1));
        expect(destructive.single.tooltip, startsWith('Leave call'));
      },
    );
  }

  testWidgets('with the canvas open the canvas button reads Close canvas, '
      'closes it, and there is no separate close X', (tester) async {
    var closed = 0;
    await pumpCanvasCallDock(
      tester,
      withCall: true,
      canvas: buildCanvasDockData(onClose: () => closed++),
    );

    expect(find.bySemanticsLabel('Open canvas'), findsNothing);
    expect(find.byIcon(AppIcons.dismiss), findsNothing);
    expect(find.bySemanticsLabel('Close canvas'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Close canvas'));
    expect(closed, 1);
  });

  testWidgets('the phone stack keeps tools and undo on top, the call below '
      'with leave last, every target at least 44dp', (tester) async {
    await pumpCanvasCallDock(
      tester,
      withCall: true,
      canvas: buildCanvasDockData(),
      width: 390,
      touch: true,
    );

    final undo = tester.getRect(find.bySemanticsLabel('Undo'));
    final mute = tester.getRect(find.bySemanticsLabel(RegExp(r'^Mute')));
    final leave = tester.getRect(_leave());
    expect(undo.center.dy, lessThan(mute.center.dy));
    expect(leave.center.dy, mute.center.dy);
    expect(leave.center.dx, greaterThan(mute.center.dx));
    for (final control in [
      undo,
      tester.getRect(find.bySemanticsLabel('Pen')),
      tester.getRect(find.bySemanticsLabel('More canvas actions')),
      tester.getRect(find.bySemanticsLabel('Close canvas')),
      mute,
      leave,
    ]) {
      expect(control.width, greaterThanOrEqualTo(AppSizes.rowTouch));
      expect(control.height, greaterThanOrEqualTo(AppSizes.rowTouch));
    }
    expect(tester.takeException(), isNull);
  });
}
