// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The image menu open on an inline image and over the fullscreen viewer, at
/// phone and desktop width. PNGs are written only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/attachment_bytes.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_view.dart';
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

const _image = api.Attachment(
  id: 'a1',
  filename: 'sunrise-over-the-harbour.png',
  contentType: 'image/png',
  size: 2048,
);

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

Future<void> _capture(
  WidgetTester tester,
  Size size,
  String name, {
  required Widget home,
  required Finder target,
  required bool longPress,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        imageExporterProvider.overrideWithValue(
          _FakeExporter(phone: size.width < 600),
        ),
        attachmentBytesProvider.overrideWith((ref, id) async => _png),
      ],
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: home,
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 200)),
  );
  await tester.pump(const Duration(milliseconds: 350));
  if (longPress) {
    await tester.longPress(target);
  } else {
    await tester.tap(target, buttons: kSecondaryButton);
  }
  await tester.pumpAndSettle();
  await expectSettled(tester, name);
  await writeSnapshot(tester, name);
  expect(tester.takeException(), isNull);
}

Widget _inline() => const Scaffold(
  body: Padding(
    padding: EdgeInsets.all(AppSpacing.s16),
    child: Align(
      alignment: Alignment.topLeft,
      child: AttachmentView(attachment: _image),
    ),
  ),
);

Widget _viewer() =>
    FullscreenImageViewer(images: const [_image], index: 0, bytes: _png);

void main() {
  setUpAll(loadRealFonts);

  testWidgets('desktop inline image', (tester) async {
    await _capture(
      tester,
      const Size(1280, 720),
      'image-menu-inline-desktop',
      home: _inline(),
      target: find.byType(Image).first,
      longPress: false,
    );
  });

  testWidgets('phone inline image', (tester) async {
    await _capture(
      tester,
      const Size(390, 844),
      'image-menu-inline-phone',
      home: _inline(),
      target: find.byType(Image).first,
      longPress: true,
    );
  });

  testWidgets('desktop viewer', (tester) async {
    await _capture(
      tester,
      const Size(1280, 720),
      'image-menu-viewer-desktop',
      home: _viewer(),
      target: find.byType(PageView),
      longPress: false,
    );
  });

  testWidgets('phone viewer', (tester) async {
    await _capture(
      tester,
      const Size(390, 844),
      'image-menu-viewer-phone',
      home: _viewer(),
      target: find.byType(PageView),
      longPress: true,
    );
  });
}
