// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The tools row with the pen's and the shape's options open, at desktop and
/// phone width in both themes. PNGs are written only under SLIMM_UI_SNAPSHOTS=1.
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
  WidgetTester tester, {
  required Size size,
  required CanvasTool tool,
  required Brightness brightness,
  required String name,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final dark = brightness == Brightness.dark;
  await tester.pumpWidget(
    ProviderScope(
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(
            brightness,
            dark ? AppTokens.dark : AppTokens.light,
          ),
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
  await tester.tap(find.byIcon(AppIcons.chevronDown));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump(const Duration(milliseconds: 350));
  await expectSettled(tester, name, allowNoText: true);
  await writeSnapshot(tester, name);
  expect(tester.takeException(), isNull);
}

void main() {
  setUpAll(loadRealFonts);

  final widths = {
    'desktop': const Size(1400, 640),
    'phone': const Size(390, 780),
  };
  final tools = {'pen': CanvasTool.pen, 'shape': CanvasTool.shape};
  for (final MapEntry(key: width, value: size) in widths.entries) {
    for (final MapEntry(key: toolName, value: tool) in tools.entries) {
      for (final brightness in Brightness.values) {
        final name = 'canvas-$toolName-options-$width-${brightness.name}';
        testWidgets(name, (tester) async {
          await _capture(
            tester,
            size: size,
            tool: tool,
            brightness: brightness,
            name: name,
          );
        });
      }
    }
  }
}
