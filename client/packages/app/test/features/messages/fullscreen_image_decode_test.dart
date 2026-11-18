// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The fullscreen viewer decodes a large animation at the screen's size, not
/// the source's, and a still keeps its pixels for zooming up to a texture a browser can hold.
library;

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/fullscreen_image_page.dart';
import 'package:slimm_design_system/design_system.dart';

final _gif = base64Decode(
  'R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==',
);
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8'
  'z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

Future<ImageProvider> _provider(WidgetTester tester, Uint8List bytes) async {
  tester.view.physicalSize = const Size(800, 600);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: FullscreenImagePage(
          filename: 'x',
          bytes: bytes,
          onDismiss: () {},
          onZoomChanged: (_) {},
        ),
      ),
    ),
  );
  return tester.widget<Image>(find.byType(Image)).image;
}

Future<Uint8List> _pngOf(int width, int height) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFF3366CC),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return png!.buffer.asUint8List();
}

/// The pixel size the page's image actually decoded to, once it has.
Future<Size> _decodedSize(WidgetTester tester) async {
  ui.Image? decoded;
  for (var i = 0; i < 200 && decoded == null; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    decoded = tester
        .widget<RawImage>(find.byWidgetPredicate((w) => w is RawImage))
        .image;
  }
  expect(decoded, isNotNull, reason: 'the image never decoded');
  return Size(decoded!.width.toDouble(), decoded.height.toDouble());
}

void main() {
  testWidgets('an animation is decoded no wider than the screen', (
    tester,
  ) async {
    final image = await _provider(tester, Uint8List.fromList(_gif));

    expect(image, isA<ResizeImage>());
    expect((image as ResizeImage).width, 800);
  });

  testWidgets('a small still keeps every pixel', (tester) async {
    await _provider(tester, Uint8List.fromList(_png));

    expect(await _decodedSize(tester), const Size(1, 1));
  });

  testWidgets('a still past the texture cap decodes within it, its shape '
      'kept', (tester) async {
    final wide = await tester.runAsync(() => _pngOf(9000, 900));
    await _provider(tester, wide!);

    final size = await _decodedSize(tester);
    expect(size.width, kFullscreenStillMaxEdge);
    expect(size.height, closeTo(kFullscreenStillMaxEdge / 10, 1));
  });
}
