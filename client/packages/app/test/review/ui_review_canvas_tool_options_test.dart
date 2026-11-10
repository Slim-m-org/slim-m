// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The pen's options on the real canvas with custom colours remembered, and the custom colour picker, at phone and desktop width.
/// Note, text and the eraser have no options and there is no highlighter, so they have no menu to capture. PNGs are written only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/providers/canvas_recent_colours.dart';
import 'package:slimm_design_system/design_system.dart';

import '../ui_snapshot_support.dart';
import 'ui_review_canvas_board.dart';
import 'ui_review_canvas_rig.dart';

const _recent = ['#3a7bd5', '#2f9e44', '#c2255c'];

Future<CanvasReviewRig> _withRecents(
  WidgetTester tester,
  String viewport,
  String theme,
) async {
  final rig = await mountReviewCanvas(
    tester,
    viewport,
    objects: sparseBoard(phone: viewport == 'phone'),
    call: reviewCall,
    theme: theme,
    prefs: {canvasRecentColoursKey: _recent},
  );
  await tester.runAsync(
    () => rig.container.read(canvasRecentColoursProvider.notifier).restore(),
  );
  await tester.tap(find.bySemanticsLabel('Pen'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  return rig;
}

Future<void> _openCaret(CanvasReviewRig rig) async {
  await rig.tester.tap(find.byIcon(AppIcons.chevronDown).first);
  await rig.tester.pump();
  await rig.settle();
}

void main() {
  setUpAll(loadRealFonts);

  for (final viewport in reviewCanvasViewports.keys) {
    testWidgets('menu-canvas-tool-options custom-colours $viewport', (t) async {
      await captureEachTheme(
        t,
        (theme) => _withRecents(t, viewport, theme),
        (rig) async {
          await _openCaret(rig);
          await t.tap(find.bySemanticsLabel('Custom ${_recent[1]}'));
          await t.pump();
          await rig.settle();
          await _openCaret(rig);
        },
        'menu-canvas-tool-options',
        state: 'custom-colours',
      );
    });

    testWidgets('menu-canvas-tool-options custom-picker $viewport', (t) async {
      await captureEachTheme(
        t,
        (theme) => _withRecents(t, viewport, theme),
        (rig) async {
          await _openCaret(rig);
          await t.tap(find.bySemanticsLabel('Custom colour'));
          await t.pump();
          await rig.settle();
          await t.enterText(
            find.byWidgetPredicate((w) => w is EditableText),
            '#8a4fff',
          );
          await t.pump();
        },
        'menu-canvas-tool-options',
        state: 'custom-picker',
      );
    });
  }
}
