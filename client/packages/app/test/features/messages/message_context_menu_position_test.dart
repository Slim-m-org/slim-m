// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The menu has to open under the pointer that opened it, not at a fixed
/// offset from the region's own corner.
///
/// Before this, `_anchorOffset` always answered with the region's own
/// top-left plus a constant inset, so a right-click or long-press anywhere
/// on a tall row opened the menu near that corner rather than under the
/// cursor - reported directly by a user as "the context menu for messages
/// also doesnt spawn under my mouse properly". The keyboard route (the
/// context-menu key, with no pointer at all) still needs a position to
/// anchor to, so it keeps that same row-corner fallback; see
/// `context_menu_reachability_test.dart` for that path.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_context_menu.dart';
import 'package:slimm_design_system/design_system.dart';

import 'message_row_harness.dart';

/// Tall and empty, so a click deep inside it cannot land on a nested
/// recognizer (text, a button) that would swallow the gesture before this
/// region's own long-press/secondary-tap ever sees it.
Widget _tallRegion() =>
    ColoredBox(color: Colors.black12, child: SizedBox(width: 400, height: 700));

Future<Rect> _pumpAndOpen(
  WidgetTester tester, {
  required Offset clickOffsetFromTop,
  required bool longPress,
}) async {
  tester.view.physicalSize = const Size(900, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    harness(
      MessageContextMenuRegion(
        content: 'hello',
        actions: noActions,
        onAddReaction: () {},
        onPickReaction: (_) {},
        child: _tallRegion(),
      ),
    ),
  );
  await tester.pumpAndSettle();

  final regionTop = tester.getTopLeft(find.byType(MessageContextMenuRegion));
  final clickPoint = regionTop + clickOffsetFromTop;

  if (longPress) {
    await tester.longPressAt(clickPoint);
  } else {
    await tester.tapAt(
      clickPoint,
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
  }
  await tester.pumpAndSettle();

  expect(find.byType(AppMenu), findsOneWidget);
  return Rect.fromLTWH(clickPoint.dx, clickPoint.dy, 0, 0);
}

void main() {
  testWidgets('a right-click opens the menu at the cursor, not the row\'s '
      'own corner', (tester) async {
    final click = await _pumpAndOpen(
      tester,
      clickOffsetFromTop: const Offset(40, 500),
      longPress: false,
    );

    final menuTop = tester.getTopLeft(find.byType(AppMenu));
    expect(
      (menuTop.dy - click.top).abs(),
      lessThan(20),
      reason:
          'the menu should land beside the click, not near the row\'s '
          'own top edge',
    );
    expect(menuTop.dy, greaterThan(click.top - 100));
  });

  testWidgets('a long-press opens the menu at the touch point too', (
    tester,
  ) async {
    final click = await _pumpAndOpen(
      tester,
      clickOffsetFromTop: const Offset(40, 300),
      longPress: true,
    );

    final menuTop = tester.getTopLeft(find.byType(AppMenu));
    expect(
      (menuTop.dy - click.top).abs(),
      lessThan(20),
      reason: 'a long, low press should not reopen near the row\'s own top',
    );
  });

  testWidgets(
    'clicking at two different points opens the menu at two different '
    'places',
    (tester) async {
      await _pumpAndOpen(
        tester,
        clickOffsetFromTop: const Offset(40, 100),
        longPress: false,
      );
      final firstMenuTop = tester.getTopLeft(find.byType(AppMenu));

      // Close it, then reopen far lower on the same tall region.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      final regionTop = tester.getTopLeft(
        find.byType(MessageContextMenuRegion),
      );
      await tester.tapAt(
        regionTop + const Offset(40, 550),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      final secondMenuTop = tester.getTopLeft(find.byType(AppMenu));

      expect(
        (secondMenuTop.dy - firstMenuTop.dy).abs(),
        greaterThan(200),
        reason:
            'a fixed row-relative anchor would open both clicks at the '
            'same place; a cursor-anchored one moves with the click',
      );
    },
  );
}
