// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// C-119: the overflow menu has no height bound or scroll, so on a short
/// window its fullest form leaves the screen.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_overflow_menu.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_tools_row.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

void main() {
  testWidgets('the fullest menu stays inside a short landscape screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomRight,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 80),
                child: CanvasOverflowMenu(
                  onPasteImage: () {},
                  canDraw: true,
                  onToggleFullscreen: () {},
                  canManage: true,
                  onClear: () async {},
                  selection: ValueNotifier('obj'),
                  onBringToFront: (_) {},
                  onSendToBack: (_) {},
                  onDeleteSelected: (_) {},
                  activityLogOpen: false,
                  onToggleActivityLog: () {},
                  tool: CanvasTool.shape,
                  shapeKind: CanvasShapeKind.rectangle,
                  onShapeKindChanged: (_) {},
                  hasSelfBubble: true,
                  selfBubbleHidden: false,
                  onToggleSelfBubbleHidden: () {},
                  hiddenTiles: const [CanvasHiddenTile(key: 'a', label: 'Ana')],
                  onShowTile: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.bySemanticsLabel('More canvas actions'));
    await tester.pumpAndSettle();

    final rect = tester.getRect(find.byType(AppMenu));
    expect(
      rect.top >= 0 && rect.bottom <= 390,
      isTrue,
      reason: 'menu spans ${rect.top}..${rect.bottom} on a 390px-high screen',
    );
  });
}
