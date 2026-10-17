// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The composer's code picker and the paste-as-code offer, at desktop and
/// phone width in the dark theme. PNGs are written only under
/// SLIMM_UI_SNAPSHOTS=1; otherwise this asserts a clean layout.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/code_block_runner.dart';

import 'composer_harness.dart';
import 'ui_snapshot_fonts.dart';
import 'ui_snapshot_support.dart' show snapshotDir, writingSnapshots;

/// The whole window, since the picker is an overlay above the composer.
Future<void> _writeWindow(WidgetTester tester, String name) async {
  if (!writingSnapshots) return;
  final view = tester.binding.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  await tester.runAsync(() async {
    final image = await layer.toImage(Offset.zero & view.size, pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    Directory(snapshotDir).createSync(recursive: true);
    File(
      '$snapshotDir/$name.png',
    ).writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

void main() {
  setUpAll(loadRealFonts);

  for (final (name, size, platform) in const [
    ('desktop', Size(1200, 700), TargetPlatform.linux),
    ('phone', Size(390, 800), TargetPlatform.iOS),
  ]) {
    Future<TextEditingController> pump(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        composerHarness(
          controller: controller,
          sends: Sends(),
          platform: platform,
          brightness: Brightness.dark,
          extraOverrides: [
            codeBlockRunnerProvider.overrideWith(
              (ref) async => const [
                api.CodeBlockRunner(
                  moduleId: 'm',
                  command: 'run',
                  language: 'python',
                ),
              ],
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      return controller;
    }

    testWidgets('code picker $name', (tester) async {
      await pump(tester);
      if (platform == TargetPlatform.iOS) {
        await tester.tap(find.bySemanticsLabel('More actions'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Insert code'));
      } else {
        await tester.tap(find.bySemanticsLabel('Insert code'));
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Inline code'), findsOneWidget);
      await _writeWindow(tester, 'composer-code-picker-$name');
    });

    testWidgets('code paste offer $name', (tester) async {
      final controller = await pump(tester);
      const pasted = 'def add(a, b):\n    return a + b\n\nprint(add(1, 2))';
      controller.value = const TextEditingValue(
        text: pasted,
        selection: TextSelection.collapsed(offset: pasted.length),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Format as code block'), findsOneWidget);
      await _writeWindow(tester, 'composer-code-paste-$name');
    });
  }
}
