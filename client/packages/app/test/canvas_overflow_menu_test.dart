// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// canvas.md: at the previous `width: 200`, this menu's own longest labels
/// truncated - "Paste image" (with its Ctrl+V hint) to "Paste i…", "Hide my
/// camera bubble" to "Hide my camera bu…" - narrower than every sibling
/// item in the same menu ("Recenter view" fit fine), which read as broken
/// rather than intentionally abbreviated.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/screens/canvas/canvas_overflow_menu.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'ui_snapshot_fonts.dart';

/// The exact chain a menu row's label sits behind: `AppMenu`'s own 6px
/// padding on each side, the item container's 10px padding on each side,
/// a 16px leading icon, and the row's 8px (desktop) spacing before the
/// label - so the label never actually gets the menu's own nominal width.
double _labelBudget(double menuWidth) =>
    menuWidth - (6 * 2) - (10 * 2) - 16 - 8;

/// Whether [text], set in the real face `AppMenuItem` renders it in, fits
/// [maxWidth] on one line - the same measurement `TextOverflow.ellipsis`
/// itself makes to decide whether to clip. Needs the real font loaded and
/// named explicitly: `AppText.ui` carries no `fontFamily` of its own and
/// leans on the ambient theme for it, which a bare `TextPainter` has none
/// of, and the test binding's own placeholder face measures every string
/// far wider than IBM Plex Sans actually does.
bool _fitsOneLine(String text, double maxWidth) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: AppText.ui.copyWith(fontFamily: AppFonts.sans),
    ),
    maxLines: 1,
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: double.infinity);
  return painter.width <= maxWidth;
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets(
    "the menu's own longest label fits on one line without truncating",
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: CanvasOverflowMenu(
              onPasteImage: () {},
              canDraw: true,
              onRecenter: () {},
              onToggleFullscreen: () {},
              canManage: false,
              onClear: () async {},
              selection: ValueNotifier(null),
              onBringToFront: (_) {},
              onSendToBack: (_) {},
              onDeleteSelected: (_) {},
              activityLogOpen: false,
              onToggleActivityLog: () {},
              tool: CanvasTool.pan,
              shapeKind: CanvasShapeKind.rectangle,
              onShapeKindChanged: (_) {},
              hasSelfBubble: true,
              selfBubbleHidden: false,
              onToggleSelfBubbleHidden: () {},
              hiddenTiles: const [],
              onShowTile: (_) {},
            ),
          ),
        ),
      );
      await tester.tap(find.bySemanticsLabel('More canvas actions'));
      await tester.pumpAndSettle();

      final menu = tester.widget<AppMenu>(find.byType(AppMenu));
      final budget = _labelBudget(menu.width);

      for (final label in const ['Hide my camera bubble', 'Recenter view']) {
        expect(
          _fitsOneLine(label, budget),
          isTrue,
          reason:
              '"$label" must fit within the menu\'s own width, not '
              'truncate to an ellipsis',
        );
      }
    },
  );
}
