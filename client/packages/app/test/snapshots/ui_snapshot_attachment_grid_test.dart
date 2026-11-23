// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The attachment grid with two, three, four and six images, at a phone and a
/// desktop column, in both themes. PNGs are written only under
/// SLIMM_UI_SNAPSHOTS=1; otherwise this asserts a clean layout.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/features/messages/providers/attachment_bytes.dart';
import 'package:slimm_app/src/features/messages/providers/attachment_preview_bytes.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_gallery.dart';
import 'package:slimm_design_system/design_system.dart';

import '../support/fake_sync.dart';
import '../ui_snapshot_support.dart';

api.Attachment _image(int i) => api.Attachment(
  id: 'img-$i',
  filename: 'photo-$i.png',
  contentType: 'image/png',
  size: 4,
);

Future<Uint8List> _swatch(int i) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final hue = (i * 57.0) % 360;
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 96, 96),
    Paint()
      ..shader = ui.Gradient.linear(Offset.zero, const Offset(96, 96), [
        HSLColor.fromAHSL(1, hue, 0.6, 0.55).toColor(),
        HSLColor.fromAHSL(1, (hue + 40) % 360, 0.6, 0.35).toColor(),
      ]),
  );
  final image = await recorder.endRecording().toImage(96, 96);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

void main() {
  setUpAll(loadRealFonts);
  const sizes = {'phone': Size(390, 900), 'desktop': Size(900, 900)};
  for (final entry in sizes.entries) {
    testWidgets('attachment grid ${entry.key} (dark+light)', (tester) async {
      tester.view.physicalSize = entry.value;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final bytes = <Uint8List>[
        for (var i = 0; i < 6; i++) (await tester.runAsync(() => _swatch(i)))!,
      ];
      Widget build(String theme) => ProviderScope(
        overrides: [
          syncControllerProvider.overrideWith(NoopSyncController.new),
          for (var i = 0; i < 6; i++)
            attachmentBytesProvider(
              'img-$i',
            ).overrideWith((ref) async => bytes[i]),
          attachmentPreviewBytesProvider.overrideWith(
            (ref, key) async => bytes[0],
          ),
        ],
        child: RepaintBoundary(
          key: snapshotBoundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: snapshotThemeData(theme),
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(AppSpacing.s16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final n in const [2, 3, 4, 6]) ...[
                      MessageAttachments(
                        attachments: [for (var i = 0; i < n; i++) _image(i)],
                      ),
                      const SizedBox(height: AppSpacing.s16),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(build('dark'));
      await tester.pump(const Duration(seconds: 1));
      await checkDarkThenLight(tester, build, (theme) async {
        await tester.pump(const Duration(seconds: 1));
        expect(tester.takeException(), isNull);
        await writeSnapshot(tester, 'attachment-grid-${entry.key}-$theme');
      });
    });
  }
}
