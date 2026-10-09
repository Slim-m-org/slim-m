// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [CanvasZoomIndicator]: the one on-screen zoom-percentage readout, driven
/// straight off [CanvasDocument.camera].
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/dock_reservation.dart';
import 'package:slimm_app/src/screens/canvas/canvas_zoom_indicator.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

Widget _wrap(Widget child) => ProviderScope(
  child: MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: Scaffold(
      body: SizedBox(width: 400, height: 400, child: Stack(children: [child])),
    ),
  ),
);

void main() {
  testWidgets('reads 100% at the default camera', (tester) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);

    await tester.pumpWidget(
      _wrap(
        CanvasZoomIndicator(
          document: document,
          tokens: AppTokens.dark,
          onFit: () {},
        ),
      ),
    );

    expect(find.text('100%'), findsOneWidget);
  });

  testWidgets('updates live as the camera zooms, with no rebuild needed', (
    tester,
  ) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    document.setViewport(const Size(400, 400));

    await tester.pumpWidget(
      _wrap(
        CanvasZoomIndicator(
          document: document,
          tokens: AppTokens.dark,
          onFit: () {},
        ),
      ),
    );
    expect(find.text('100%'), findsOneWidget);

    document.setCamera(const Camera(zoom: 2));
    await tester.pump();

    expect(find.text('200%'), findsOneWidget);
    expect(find.text('100%'), findsNothing);
  });

  testWidgets('tapping the chip fits the view', (tester) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    var fitted = 0;

    await tester.pumpWidget(
      _wrap(
        CanvasZoomIndicator(
          document: document,
          tokens: AppTokens.dark,
          onFit: () => fitted++,
        ),
      ),
    );
    await tester.tap(find.byTooltip('Fit view'));

    expect(fitted, 1);
  });

  testWidgets('is 28px tall and leaves the rest of the surface untouched', (
    tester,
  ) async {
    final document = CanvasDocument();
    addTearDown(document.dispose);
    var fitted = 0;

    await tester.pumpWidget(
      _wrap(
        CanvasZoomIndicator(
          document: document,
          tokens: AppTokens.dark,
          onFit: () => fitted++,
        ),
      ),
    );

    final chip = tester.getRect(find.byType(InkWell));
    expect(chip.height, 28);
    await tester.tapAt(const Offset(700, 300));
    expect(fitted, 0);
  });

  for (final (pane, above) in [(795.0, true), (1000.0, false)]) {
    testWidgets('in a $pane wide pane it rides above the dock: $above', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final document = CanvasDocument();
      addTearDown(document.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [bottomDockReservationProvider.overrideWith((ref) => 52)],
          child: MaterialApp(
            theme: buildTheme(Brightness.dark, AppTokens.dark),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: pane,
                  height: 600,
                  child: Stack(
                    children: [
                      CanvasZoomIndicator(
                        document: document,
                        tokens: AppTokens.dark,
                        onFit: () {},
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      final chip = tester.getRect(find.byType(InkWell));
      expect(chip.bottom, above ? lessThan(600 - 52) : greaterThan(570));
    });
  }
}
