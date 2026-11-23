// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

Future<int> _taps(WidgetTester tester, AppTokens tokens) async {
  var taps = 0;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark, tokens),
      home: ThemeBackdrop(
        // Top-right is where the web hangs, so a tap there is the real test.
        child: Align(
          alignment: Alignment.topRight,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => taps++,
            child: const SizedBox(key: Key('target'), width: 100, height: 100),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('target')));
  return taps;
}

void main() {
  testWidgets('halloween paints the backdrop and it takes no taps', (
    tester,
  ) async {
    final taps = await _taps(tester, AppTokens.halloween);

    expect(find.byKey(const Key('theme_backdrop')), findsOneWidget);
    expect(taps, 1);
    expect(
      find.ancestor(
        of: find.byKey(const Key('theme_backdrop')),
        matching: find.byType(IgnorePointer),
      ),
      findsWidgets,
    );
  });

  for (final entry in {
    'dark': AppTokens.dark,
    'forest': AppTokens.forest,
    'light': AppTokens.light,
  }.entries) {
    testWidgets('${entry.key} has no backdrop', (tester) async {
      await _taps(tester, entry.value);

      expect(find.byKey(const Key('theme_backdrop')), findsNothing);
    });
  }

  test('high contrast keeps the backdrop', () {
    expect(
      applyHighContrast(AppTokens.halloween).backdrop,
      AppBackdrop.halloweenWebs,
    );
  });

  testWidgets('the cobwebs stay inside their corners', (tester) async {
    const size = Size(390, 844);
    final rec = ui.PictureRecorder();
    const HalloweenWebsPainter().paint(Canvas(rec), size);
    final image = await tester.runAsync(
      () => rec.endRecording().toImage(390, 844),
    );
    final data = (await tester.runAsync(() => image!.toByteData()))!;
    const reach = 56.0;
    const specks = [
      Offset(0.12, 0.18),
      Offset(0.31, 0.07),
      Offset(0.58, 0.13),
      Offset(0.83, 0.34),
      Offset(0.94, 0.62),
      Offset(0.72, 0.9),
      Offset(0.44, 0.82),
      Offset(0.21, 0.57),
    ];
    var stray = 0;
    for (var y = 0; y < 844; y++) {
      for (var x = 0; x < 390; x++) {
        if (data.getUint8((y * 390 + x) * 4 + 3) == 0) continue;
        final inTopRight = x >= 390 - reach && y <= reach;
        final inBottomLeft = x <= reach && y >= 844 - reach;
        final nearSpeck = specks.any(
          (s) =>
              (Offset(x.toDouble(), y.toDouble()) -
                      Offset(s.dx * size.width, s.dy * size.height))
                  .distance <=
              3,
        );
        if (!inTopRight && !inBottomLeft && !nearSpeck) stray++;
      }
    }
    expect(stray, 0);
  });
}
