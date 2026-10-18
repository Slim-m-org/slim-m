// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A stroke lands at the same world points whatever the window width or
/// device pixel ratio, so two viewers of one canvas never disagree on where
/// ink is.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

Future<List<Offset>> _draw(
  WidgetTester tester, {
  required Size size,
  required double ratio,
  required Camera camera,
}) async {
  tester.view.physicalSize = size * ratio;
  tester.view.devicePixelRatio = ratio;
  addTearDown(tester.view.reset);
  final document = CanvasDocument();
  addTearDown(document.dispose);
  List<Offset>? drawn;
  await tester.pumpWidget(
    MaterialApp(
      home: CanvasSurface(
        document: document,
        ink: const Color(0xFFE86A5C),
        onStroke: (points) => drawn = points,
      ),
    ),
  );
  document.setCamera(camera);
  await tester.pump();
  final gesture = await tester.startGesture(const Offset(100, 100));
  await gesture.moveTo(const Offset(180, 140));
  await gesture.up();
  await tester.pump();
  return drawn!;
}

void main() {
  const camera = Camera(x: 500, y: 300, zoom: 2);

  testWidgets('the same pointer path is the same world path at 390 and 1280 '
      'wide, DPR 1 and 2', (tester) async {
    final narrow = await _draw(
      tester,
      size: const Size(390, 700),
      ratio: 2,
      camera: camera,
    );
    final wide = await _draw(
      tester,
      size: const Size(1280, 800),
      ratio: 1,
      camera: camera,
    );

    expect(wide, narrow);
    expect(narrow.first, const Offset(550, 350));
    expect(narrow.last.dx, closeTo(590, 1));
  });
}
