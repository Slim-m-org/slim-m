// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The tile's resize grip follows the same touch-target rule as the icon
/// buttons beside it: 44dp at touch widths, the 26dp glyph box otherwise,
/// and it reports a drag rather than letting it fall through to the canvas.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_tile_controls.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _host({required bool touch, required VoidCallback onEnd, Key? key}) =>
    MaterialApp(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: AppTouchTargets(
        enabled: touch,
        child: Scaffold(
          body: Center(
            child: TileResizeGrip(
              key: key,
              onUpdate: (_) {},
              onEnd: (_) => onEnd(),
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('the grip hit area is 44dp at touch widths', (tester) async {
    await tester.pumpWidget(_host(touch: true, onEnd: () {}));
    expect(tester.getSize(find.byType(TileResizeGrip)).shortestSide, 44);
  });

  testWidgets('the grip keeps its 26dp box at pointer widths', (tester) async {
    await tester.pumpWidget(_host(touch: false, onEnd: () {}));
    expect(
      tester.getSize(find.byType(TileResizeGrip)).shortestSide,
      AppSizes.controlSm,
    );
  });

  testWidgets('a drag on the grip ends through onEnd', (tester) async {
    var ended = 0;
    await tester.pumpWidget(_host(touch: true, onEnd: () => ended++));
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(TileResizeGrip)),
      kind: PointerDeviceKind.touch,
    );
    await gesture.moveBy(const Offset(30, 30));
    await gesture.up();
    await tester.pump();
    expect(ended, 1);
  });
}
