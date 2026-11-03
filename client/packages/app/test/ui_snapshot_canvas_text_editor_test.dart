// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas text editor at desktop and phone width in both themes. PNGs are
/// written only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/providers/canvas_text_props.dart';
import 'package:slimm_app/src/features/canvas/widgets/canvas_text_editor.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'support/mid_flight_capture.dart';
import 'ui_snapshot_support.dart';

Future<void> _capture(
  WidgetTester tester, {
  required Size size,
  required Brightness brightness,
  required String name,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final document = CanvasDocument()..setViewport(size);
  addTearDown(document.dispose);
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
            body: CanvasTextEditor(
              document: document,
              anchor: Offset(size.width / 4, size.height / 3),
              initial: const CanvasTextProps(text: 'BRUH'),
              onSave: (_) {},
              onCancel: () {},
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

  final widths = {
    'desktop': const Size(1400, 640),
    'phone': const Size(390, 780),
  };
  for (final MapEntry(key: width, value: size) in widths.entries) {
    for (final brightness in Brightness.values) {
      final name = 'canvas-text-editor-$width-${brightness.name}';
      testWidgets(name, (tester) async {
        await _capture(tester, size: size, brightness: brightness, name: name);
      });
    }
  }
}
