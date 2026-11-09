// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The speaking ring and the spinner animate every frame for as long as they
/// are on screen, so each must repaint only itself: without its own layer a
/// frame of either re-records everything up to the nearest boundary, which in a
/// call is the whole rail or pane.
///
/// A neighbour that counts its own paints stands in for that pane.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

class _PaintCounter extends CustomPainter {
  int paints = 0;

  @override
  void paint(Canvas canvas, Size size) => paints++;

  @override
  bool shouldRepaint(_PaintCounter oldDelegate) => false;
}

Future<int> _neighbourPaintsWhileAnimating(
  WidgetTester tester,
  Widget animated,
) async {
  final neighbour = _PaintCounter();
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(
        body: Column(
          children: [
            SizedBox.square(
              dimension: 10,
              child: CustomPaint(painter: neighbour),
            ),
            animated,
          ],
        ),
      ),
    ),
  );
  await tester.pump();
  final settled = neighbour.paints;
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  return neighbour.paints - settled;
}

void main() {
  testWidgets('a pulsing speaking ring does not repaint its neighbours', (
    tester,
  ) async {
    final extra = await _neighbourPaintsWhileAnimating(
      tester,
      const AppSpeakingRing(
        color: Colors.green,
        size: 40,
        child: SizedBox.square(dimension: 40),
      ),
    );

    expect(extra, 0);
  });

  testWidgets('a spinning spinner does not repaint its neighbours', (
    tester,
  ) async {
    final extra = await _neighbourPaintsWhileAnimating(
      tester,
      const AppSpinner(),
    );

    expect(extra, 0);
  });
}
