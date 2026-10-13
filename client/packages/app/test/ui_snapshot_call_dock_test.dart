// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call dock in a call, and with the canvas open, at desktop and phone
/// width in both themes. PNGs are written only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/canvas_call_dock_fixtures.dart';
import 'support/mid_flight_capture.dart';
import 'ui_snapshot_support.dart';

Future<void> _capture(
  WidgetTester tester, {
  required Size size,
  required bool canvasOpen,
  required Brightness brightness,
  required String name,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await pumpCanvasCallDock(
    tester,
    withCall: true,
    canvas: canvasOpen ? buildCanvasDockData() : null,
    width: size.width,
    hug: true,
    touch: size.width < 600,
    brightness: brightness,
    boundaryKey: snapshotBoundary,
  );
  await tester.pump(const Duration(milliseconds: 350));
  await expectSettled(tester, name, allowNoText: true);
  await writeSnapshot(tester, name);
  expect(tester.takeException(), isNull);
}

void main() {
  setUpAll(loadRealFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final brightness in Brightness.values) {
    for (final canvasOpen in [false, true]) {
      for (final (label, size) in [
        ('desktop', const Size(1400, 200)),
        ('phone', const Size(390, 200)),
      ]) {
        final name =
            'call-dock-${canvasOpen ? 'canvas' : 'call'}-$label-${brightness.name}';
        testWidgets(name, (tester) async {
          await _capture(
            tester,
            size: size,
            canvasOpen: canvasOpen,
            brightness: brightness,
            name: name,
          );
        });
      }
    }
  }
}
