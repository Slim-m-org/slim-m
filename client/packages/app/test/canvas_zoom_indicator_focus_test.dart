// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Fit view pill must show a visible focus ring under keyboard focus.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_zoom_indicator.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

bool _paintsFocusRing(WidgetTester tester, Color ring) {
  final scope = find.byType(CanvasZoomIndicator);
  final decorated = find.descendant(
    of: scope,
    matching: find.byType(DecoratedBox),
  );
  for (final e in decorated.evaluate()) {
    final d = (e.widget as DecoratedBox).decoration;
    if (d is BoxDecoration && d.border is Border) {
      final b = d.border! as Border;
      if (b.top.color == ring) return true;
    }
    if (d is ShapeDecoration) {
      final s = d.shape;
      if (s is OutlinedBorder && s.side.color == ring) return true;
    }
  }
  final materials = find.descendant(of: scope, matching: find.byType(Material));
  for (final e in materials.evaluate()) {
    final s = (e.widget as Material).shape;
    if (s is OutlinedBorder && s.side.color == ring) return true;
  }
  return false;
}

void main() {
  testWidgets('keyboard focus on the Fit view pill draws the focus ring', (
    tester,
  ) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 400,
              child: Stack(
                children: [
                  CanvasZoomIndicator(
                    document: document,
                    tokens: AppTokens.dark,
                    onFit: () {},
                    onBringIn: () {},
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(
      _paintsFocusRing(tester, AppTokens.dark.focusRing),
      isTrue,
      reason: 'focused Fit view pill shows no tokens.focusRing outline',
    );
  });
}
