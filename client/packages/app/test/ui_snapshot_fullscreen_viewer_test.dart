// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The fullscreen image viewer open on a two-image message, at phone and
/// desktop width. PNGs are written only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/widgets/fullscreen_image_viewer.dart';
import 'package:slimm_app/src/features/messages/widgets/image_export.dart';
import 'package:slimm_design_system/design_system.dart';

import 'support/mid_flight_capture.dart';
import 'ui_snapshot_support.dart';

final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAT0lEQVR42u3PQQkA'
  'AAgEsAtmMCMaywi+hcEKLNP1WgQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE'
  'BAQEBAQEBAQEBAQEBAQEBAQELguFPsFaQDQP9QAAAABJRU5ErkJggg==',
);

const _images = [
  api.Attachment(
    id: 'a1',
    filename: 'sunrise-over-the-harbour.png',
    contentType: 'image/png',
    size: 2048,
  ),
  api.Attachment(
    id: 'a2',
    filename: 'second.png',
    contentType: 'image/png',
    size: 2048,
  ),
];

class _FakeExporter implements ImageExporter {
  _FakeExporter({required this.phone});

  final bool phone;

  @override
  bool get canShare => phone;

  @override
  bool get savesToLibrary => phone;

  @override
  Future<void> share(
    Uint8List bytes, {
    required String filename,
    required String contentType,
    Rect? origin,
  }) async {}

  @override
  Future<bool> save(Uint8List bytes, {required String filename}) async => true;
}

Future<void> _capture(WidgetTester tester, Size size, String name) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        imageExporterProvider.overrideWithValue(
          _FakeExporter(phone: size.width < 600),
        ),
      ],
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: FullscreenImageViewer(images: _images, index: 0, bytes: _png),
        ),
      ),
    ),
  );
  await tester.pump();
  // Image decoding is engine work the fake clock never completes.
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 200)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await expectSettled(tester, name);
  await writeSnapshot(tester, name);
  expect(tester.takeException(), isNull);
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets('phone width', (tester) async {
    await _capture(tester, const Size(390, 844), 'fullscreen-viewer-phone');
  });

  testWidgets('desktop width', (tester) async {
    await _capture(tester, const Size(1400, 880), 'fullscreen-viewer-desktop');
  });
}
