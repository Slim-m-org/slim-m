// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas tools row's own accessibility surface: semantics reachability
/// at phone width, hover tooltips, the disabled-undo explanation, keyboard
/// dismissal of the overflow menu, and the Ctrl+V hint's pointer/touch
/// split. Split out of `canvas_tools_row_test.dart` once this pushed it past
/// the 500-line hard limit.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

import 'support/canvas_tools_row_fixtures.dart';

void main() {
  /// Every affordance this row adds - pen, eraser, undo, the overflow, and
  /// close - carries a semantics node at the narrowest supported width, so a
  /// screen reader always reaches it. This does not prove a sighted touch
  /// can reach the same node with a bare tap: two of these sit past the
  /// tool strip's own scroll offset at this width, and the tests in
  /// `canvas_tools_row_touch_reach_test.dart` cover that separately.
  testWidgets('every new affordance is reachable by touch, at phone width', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrapCanvasToolsRow(
        buildCanvasToolsRow(canManage: true, canUndo: true),
        width: 320,
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    for (final label in [
      'Pan',
      'Pen',
      'Note',
      'Shape',
      'Eraser',
      'Undo',
      'More canvas actions',
    ]) {
      expect(
        find.bySemanticsLabel(label),
        findsOneWidget,
        reason: '$label must be reachable at the narrowest supported width',
      );
    }
  });

  /// A mouse hover is the only route a sighted desktop user has to learn a
  /// button's name without already knowing the icon, so every button here
  /// needs one - not just a screen-reader-only semantic label.
  testWidgets('every toolbar and overflow button carries a hover tooltip', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrapCanvasToolsRow(buildCanvasToolsRow(canManage: true, canUndo: true)),
    );

    for (final tooltip in ['Pen', 'Note', 'Undo', 'More canvas actions']) {
      expect(
        find.byTooltip(tooltip),
        findsOneWidget,
        reason:
            '$tooltip must be reachable on hover, not only by screen reader',
      );
    }
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip &&
            (widget.message?.startsWith('Pan the canvas') ?? false),
      ),
      findsOneWidget,
      reason: 'Pan\'s tooltip is the only place Shift-frees-aspect is said',
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip &&
            (widget.message?.contains('erases ink and shapes') ?? false),
      ),
      findsOneWidget,
      reason: 'Eraser\'s tooltip is the only place its scope is said',
    );
  });

  /// A disabled control must say why, per the design language: greyed out
  /// with no explanation reads as broken rather than as "nothing to do yet".
  testWidgets('the undo tooltip explains why it is disabled', (tester) async {
    await tester.pumpWidget(
      wrapCanvasToolsRow(buildCanvasToolsRow(canUndo: false)),
    );
    expect(find.byTooltip('Nothing to undo yet'), findsOneWidget);
    expect(find.byTooltip('Undo'), findsNothing);

    await tester.pumpWidget(
      wrapCanvasToolsRow(buildCanvasToolsRow(canUndo: true)),
    );
    expect(find.byTooltip('Undo'), findsOneWidget);
    expect(find.byTooltip('Nothing to undo yet'), findsNothing);
  });

  /// The trigger button is already an ordinary tab stop reachable by Tab and
  /// Enter/Space, the same as any other `AppIconButton`; what the message
  /// context menu needed and this lacked is what happens once it is open.
  testWidgets('Escape closes the overflow menu once it is open', (
    tester,
  ) async {
    await tester.pumpWidget(wrapCanvasToolsRow(buildCanvasToolsRow()));

    await tester.tap(find.bySemanticsLabel('More canvas actions'));
    await tester.pumpAndSettle();
    expect(find.text('Paste image'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(find.text('Paste image'), findsNothing);
  });

  /// Ctrl+V already works from anywhere in the pane; nothing said so until
  /// this hint, which is why it belongs in the one menu item that duplicates
  /// what the shortcut already does.
  testWidgets('Paste image shows a Ctrl+V hint on a pointer layout', (
    tester,
  ) async {
    await tester.pumpWidget(wrapCanvasToolsRow(buildCanvasToolsRow()));

    await tester.tap(find.bySemanticsLabel('More canvas actions'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppKbd, 'Ctrl'), findsOneWidget);
    expect(find.widgetWithText(AppKbd, 'V'), findsOneWidget);
  });

  /// The same "no finger can press it" rule the channel search field's own
  /// Ctrl+K hint already follows.
  testWidgets('the Ctrl+V hint is dropped on a touch layout', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrapCanvasToolsRow(buildCanvasToolsRow()));

    await tester.tap(find.bySemanticsLabel('More canvas actions'));
    await tester.pumpAndSettle();

    expect(find.byType(AppKbd), findsNothing);
  });
}
