// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The right-click and long-press menu on an image: Copy image, Save image.
///
/// `flutter test` reports a desktop host for every run, so the phone branch
/// is driven through a fake [ImageExporter] with a phone's capabilities and a
/// 390px window, never by trusting the host.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/attachment_bytes.dart';
import 'package:slimm_app/src/features/messages/providers/attachment_preview_bytes.dart';
import 'package:slimm_app/src/features/messages/widgets/attachment_view.dart';
import 'package:slimm_app/src/features/messages/widgets/fullscreen_image_viewer.dart';
import 'package:slimm_app/src/features/messages/widgets/image_actions.dart';
import 'package:slimm_app/src/features/messages/widgets/image_export.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAT0lEQVR42u3PQQkA'
  'AAgEsAtmMCMaywi+hcEKLNP1WgQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE'
  'BAQEBAQEBAQEBAQEBAQEBAQELguFPsFaQDQP9QAAAABJRU5ErkJggg==',
);

const _image = api.Attachment(
  id: 'a1',
  filename: 'holiday.png',
  contentType: 'image/png',
  size: 2048,
);

class _FakeWriter implements ClipboardImageWriter {
  _FakeWriter({this.refuse = false});

  final bool refuse;
  final copied = <Uint8List>[];

  @override
  Future<void> writeImage(Future<Uint8List> bytes) async {
    final resolved = await bytes;
    if (refuse) {
      throw const ClipboardImageWriteException(
        'The browser would not copy this image.',
      );
    }
    copied.add(resolved);
  }
}

class _FakeExporter implements ImageExporter {
  _FakeExporter({required this.phone});

  final bool phone;
  final saved = <Uint8List>[];

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
  Future<bool> save(Uint8List bytes, {required String filename}) async {
    saved.add(bytes);
    return true;
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required Size size,
  required _FakeWriter writer,
  required _FakeExporter exporter,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.runAsync(() async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          clipboardImageWriterProvider.overrideWithValue(writer),
          imageExporterProvider.overrideWithValue(exporter),
          attachmentBytesProvider.overrideWith((ref, id) async => _png),
          attachmentPreviewBytesProvider.overrideWith((ref, key) async => _png),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: const Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: AttachmentView(attachment: _image),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });
  await tester.pumpAndSettle();
}

Future<void> _rightClick(WidgetTester tester, Finder target) async {
  await tester.tap(target, buttons: kSecondaryButton);
  await tester.pumpAndSettle();
}

/// The provider's future completes in the real zone, so FakeAsync alone never sees it.
Future<void> _letActionFinish(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
  );
  await tester.pumpAndSettle();
}

Finder _row(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(AppMenuItem));

void main() {
  testWidgets('right-click offers Copy image and Save image at pointer size', (
    tester,
  ) async {
    final writer = _FakeWriter();
    await _pump(
      tester,
      size: const Size(1280, 800),
      writer: writer,
      exporter: _FakeExporter(phone: false),
    );

    await _rightClick(tester, find.byType(Image).first);

    expect(_row('Copy image'), findsOneWidget);
    expect(_row('Save image'), findsOneWidget);
    expect(tester.getSize(_row('Copy image')).height, 34);
    expect(find.text('Copy link'), findsNothing);
  });

  testWidgets('Copy image hands the seam the attachment bytes', (tester) async {
    final writer = _FakeWriter();
    await _pump(
      tester,
      size: const Size(1280, 800),
      writer: writer,
      exporter: _FakeExporter(phone: false),
    );

    await _rightClick(tester, find.byType(Image).first);
    await tester.tap(find.text('Copy image'));
    await _letActionFinish(tester);

    expect(writer.copied, [_png]);
    expect(find.text('Copy image'), findsNothing);
  });

  testWidgets(
    'long-press on a phone opens 44px-plus rows and saves to photos',
    (tester) async {
      final exporter = _FakeExporter(phone: true);
      await _pump(
        tester,
        size: const Size(390, 800),
        writer: _FakeWriter(),
        exporter: exporter,
      );

      await tester.longPress(find.byType(Image).first);
      await tester.pumpAndSettle();

      expect(
        tester.getSize(_row('Copy image')).height,
        greaterThanOrEqualTo(44),
      );
      expect(
        tester.getSize(_row('Save to photos')).height,
        greaterThanOrEqualTo(44),
      );
      await tester.tap(find.text('Save to photos'));
      await _letActionFinish(tester);
      expect(exporter.saved, [_png]);
    },
  );

  testWidgets('a refused copy shows the persistent error, never a SnackBar', (
    tester,
  ) async {
    await _pump(
      tester,
      size: const Size(1280, 800),
      writer: _FakeWriter(refuse: true),
      exporter: _FakeExporter(phone: false),
    );

    await _rightClick(tester, find.byType(Image).first);
    await tester.tap(find.text('Copy image'));
    await _letActionFinish(tester);

    expect(
      find.descendant(
        of: find.byType(AppErrorState),
        matching: find.text('The browser would not copy this image.'),
      ),
      findsOneWidget,
    );
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('the fullscreen viewer opens the same menu on right-click', (
    tester,
  ) async {
    final writer = _FakeWriter();
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            clipboardImageWriterProvider.overrideWithValue(writer),
            imageExporterProvider.overrideWithValue(
              _FakeExporter(phone: false),
            ),
            attachmentBytesProvider.overrideWith((ref, id) async => _png),
          ],
          child: MaterialApp(
            theme: buildTheme(Brightness.dark, AppTokens.dark),
            home: FullscreenImageViewer(
              images: const [_image],
              index: 0,
              bytes: _png,
            ),
          ),
        ),
      );
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();

    await _rightClick(tester, find.byType(PageView));
    await tester.tap(find.text('Copy image').last);
    await _letActionFinish(tester);

    expect(writer.copied, [_png]);
  });
}
