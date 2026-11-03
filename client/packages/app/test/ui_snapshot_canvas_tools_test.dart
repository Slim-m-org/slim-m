// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas tools row at desktop and phone width, each on the tool it opens
/// with. PNGs are written only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'support/canvas_tools_row_fixtures.dart';
import 'support/mid_flight_capture.dart';
import 'ui_snapshot_support.dart';

Future<void> _capture(
  WidgetTester tester,
  Size size,
  CanvasTool tool,
  String name,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.s16),
                child: buildCanvasToolsRow(tool: tool),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 350));
  await expectSettled(tester, name, allowNoText: true);
  await writeSnapshot(tester, name);
  expect(tester.takeException(), isNull);
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets('desktop width', (tester) async {
    await _capture(
      tester,
      const Size(1400, 240),
      CanvasTool.pen,
      'canvas-tools-desktop',
    );
  });

  testWidgets('phone width', (tester) async {
    await _capture(
      tester,
      const Size(390, 240),
      CanvasTool.pan,
      'canvas-tools-phone',
    );
  });
}
