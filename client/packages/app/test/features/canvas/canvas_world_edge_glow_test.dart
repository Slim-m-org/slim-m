// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [CanvasWorldEdgeGlow]: the visible half of the world-edge feedback,
/// driven by either notifier it merges.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_world_edge_glow.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

Widget _wrap(Widget child) => MaterialApp(
  theme: buildTheme(Brightness.dark, AppTokens.dark),
  home: Scaffold(
    body: SizedBox(width: 400, height: 400, child: Stack(children: [child])),
  ),
);

double _opacity(WidgetTester tester) =>
    tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity;

void main() {
  testWidgets('invisible while neither notifier reports the edge', (
    tester,
  ) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(overrides.dispose);

    await tester.pumpWidget(
      _wrap(
        CanvasWorldEdgeGlow(
          document: document,
          tileOverrides: overrides,
          tokens: AppTokens.dark,
        ),
      ),
    );

    expect(_opacity(tester), 0);
  });

  testWidgets('shows once the camera clamp engages, and hides again once it '
      "doesn't", (tester) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    document.setViewport(const Size(1000, 800));
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(overrides.dispose);

    await tester.pumpWidget(
      _wrap(
        CanvasWorldEdgeGlow(
          document: document,
          tileOverrides: overrides,
          tokens: AppTokens.dark,
        ),
      ),
    );

    document.setCamera(const Camera(x: worldLimit + 500, y: 0, zoom: 1));
    await tester.pump();
    expect(_opacity(tester), 1);

    document.setCamera(const Camera());
    await tester.pump();
    expect(_opacity(tester), 0);
  });

  testWidgets('shows once a tile-drag clamp engages, independent of the '
      'camera', (tester) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(overrides.dispose);

    await tester.pumpWidget(
      _wrap(
        CanvasWorldEdgeGlow(
          document: document,
          tileOverrides: overrides,
          tokens: AppTokens.dark,
        ),
      ),
    );

    overrides.setRect('camera:a', Rect.fromLTWH(worldLimit + 500, 0, 220, 160));
    await tester.pump();

    expect(_opacity(tester), 1);
  });
}
