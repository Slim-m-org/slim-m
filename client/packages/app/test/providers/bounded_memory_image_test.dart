// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A picture that declares more pixels than a screen could use is refused
/// before any bitmap is allocated, on every surface that draws sender bytes.
library;

import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/bounded_image_decode.dart';

import '../support/declared_size_png.dart';

Future<Object?> _errorOf(WidgetTester tester, ImageProvider provider) async {
  Object? error;
  final stream = provider.resolve(ImageConfiguration.empty);
  final listener = ImageStreamListener(
    (info, _) => info.dispose(),
    onError: (e, _) => error = e,
  );
  stream.addListener(listener);
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 300)),
  );
  stream.removeListener(listener);
  return error;
}

void main() {
  testWidgets('a 50000 x 50000 canvas is refused as too large', (tester) async {
    final error = await _errorOf(
      tester,
      ResizeImage(BoundedMemoryImage(declaredSizePng(50000, 50000)), width: 64),
    );
    expect(error, isA<ImageTooLargeException>());
  });

  testWidgets('an ordinary picture still decodes', (tester) async {
    final error = await _errorOf(
      tester,
      ResizeImage(BoundedMemoryImage(solidPng(40, 20)), width: 16),
    );
    expect(error, isNull);
  });

  testWidgets('ten small PNGs each declaring 9999 x 9999 are all refused', (
    tester,
  ) async {
    final bytes = declaredSizePng(9999, 9999);
    for (var i = 0; i < 10; i++) {
      final error = await _errorOf(
        tester,
        ResizeImage(BoundedMemoryImage(Uint8List.fromList(bytes)), width: 64),
      );
      expect(error, isA<ImageTooLargeException>(), reason: 'tile $i');
    }
  });

  test(
    'formats the engine downsamples while decoding get a higher ceiling',
    () {
      final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]);
      final webp = Uint8List.fromList([
        ...'RIFF'.codeUnits, 0, 0, 0, 0, ...'WEBP'.codeUnits, //
      ]);
      final gif = Uint8List.fromList('GIF89a'.codeUnits);
      final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47]);

      expect(declaredPixelCeiling(jpeg), kMaxDeclaredScaledDecodePixels);
      expect(declaredPixelCeiling(webp), kMaxDeclaredScaledDecodePixels);
      expect(declaredPixelCeiling(gif), kMaxDeclaredGifPixels);
      expect(declaredPixelCeiling(png), kMaxDeclaredPixels);
      expect(108 * 1000 * 1000, lessThan(declaredPixelCeiling(jpeg)));
    },
  );
}
