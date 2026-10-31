// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every registered overlay that opens as a desktop dialog puts its first
/// content the same distance below the card's top edge. The audit measured 3
/// to 4 px on three of them and 20 on the rest.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

import '../support/overlay_registry.dart';
import '../ui_snapshot_support.dart';

/// Open with their own first row or search field, so only the floor applies.
const _ownLayout = {'composer-actions-sheet', 'emoji-picker-sheet'};

/// Longer than the card, so the last row is wherever the scroll left it.
const _scrolls = {'whats-new-sheet'};

void main() {
  setUpAll(loadRealFonts);

  for (final overlay in overlays.entries) {
    testWidgets('${overlay.key} opens its content a fixed inset below the top '
        'edge of the dialog card', (tester) async {
      tester.view.physicalSize = overlayViewports['desktop']!;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final fixture = await fixtureContainer();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: fixture.container,
          child: MaterialApp.router(
            debugShowCheckedModeBanner: false,
            theme: buildTheme(Brightness.light, AppTokens.light),
            routerConfig: overlayRouter(overlay.value),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text(overlayOpenerLabel));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(milliseconds: 350));

      final dialog = find.byType(Dialog);
      if (dialog.evaluate().isNotEmpty) {
        final card = find
            .descendant(of: dialog, matching: find.byType(Material))
            .first;
        final top = tester.getTopLeft(card).dy;
        final content = find.descendant(
          of: card,
          matching: find.byWidgetPredicate(
            (w) => w is Text || w is Icon || w is TextField,
          ),
        );
        final inset = content
            .evaluate()
            .map(
              (e) =>
                  (e.renderObject! as RenderBox).localToGlobal(Offset.zero).dy -
                  top,
            )
            .reduce((a, b) => a < b ? a : b);
        final cardBottom = tester.getBottomLeft(card).dy;
        final gap = content
            .evaluate()
            .map(
              (e) =>
                  cardBottom -
                  (e.renderObject! as RenderBox)
                      .localToGlobal(
                        Offset(0, (e.renderObject! as RenderBox).size.height),
                      )
                      .dy,
            )
            .reduce((a, b) => a < b ? a : b);
        if (!_ownLayout.contains(overlay.key) &&
            !_scrolls.contains(overlay.key)) {
          expect(gap, greaterThanOrEqualTo(8), reason: '${overlay.key} bottom');
        }
        expect(
          inset,
          _ownLayout.contains(overlay.key)
              ? greaterThanOrEqualTo(kSheetDialogTopInset)
              : closeTo(kSheetDialogTopInset, 0.5),
          reason: '${overlay.key} content starts $inset px under the card top',
        );
      }
      await teardownFixture(tester, fixture.container, fixture.db);
    });
  }
}
