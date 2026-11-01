// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The card around a module's scene hugs the board: its width is the frame's
/// plus a small padding, never the whole message row. Layout follows width
/// (desktop-vs-mobile.md, "The one rule"); no surface rule applies, the card
/// is inline message content.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/modules/widgets/app_surface_view.dart';
import 'package:slimm_app/src/features/modules/widgets/module_scene_frame.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../app_surface_card_support.dart';
import '../../module_scene_fixtures.dart';

Rect _frame(WidgetTester tester) => tester.getRect(
  find
      .descendant(
        of: find.byType(ModuleSceneFrame),
        matching: find.byType(Container),
      )
      .first,
);

Rect _card(WidgetTester tester) => tester.getRect(
  find
      .descendant(
        of: find.byType(AppSurfaceView),
        matching: find.byType(Container),
      )
      .first,
);

void main() {
  for (final (label, window, rowWidth) in const [
    ('desktop', 792.0, 760.0),
    ('phone', 390.0, 358.0),
  ]) {
    for (final entry in shippedScenes.entries) {
      testWidgets('${entry.key} card hugs its frame at $label width', (
        tester,
      ) async {
        await pumpAppCard(tester, scene: entry.value, windowWidth: window);
        final card = _card(tester);
        final frame = _frame(tester);
        const padding = AppSpacing.s8 + 1;
        expect(card.left, 16, reason: 'starts at the row edge');
        expect(card.width, lessThanOrEqualTo(rowWidth));
        expect(
          card.width,
          closeTo(frame.width + 2 * padding, 2),
          reason: 'frame plus a small padding and the hairline border',
        );
        expect(frame.left - card.left, closeTo(padding, 1));
        expect(
          find.descendant(
            of: find.byType(AppSurfaceView),
            matching: find.text('status'),
          ),
          findsOneWidget,
        );
        final caption = tester.getRect(find.text('status'));
        expect(caption.right, lessThanOrEqualTo(card.right));
      });
    }
  }

  testWidgets('a wide card lets a board grow past the phone edge', (
    tester,
  ) async {
    await pumpAppCard(
      tester,
      scene: shippedScenes['tic-tac-toe']!,
      windowWidth: 1200,
    );
    expect(_frame(tester).width, greaterThan(ModuleSceneFrame.maxInlineEdge));
    expect(
      _frame(tester).width,
      lessThanOrEqualTo(ModuleSceneFrame.maxWideInlineEdge + 2),
    );
    await pumpAppCard(
      tester,
      scene: shippedScenes['tic-tac-toe']!,
      windowWidth: 390,
    );
    expect(_frame(tester).width, lessThanOrEqualTo(358));
  });
}
