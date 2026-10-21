// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A clipboard image is staged as PNG whatever format the platform handed
/// over: Windows offers a bitmap when the copying app put no PNG beside it.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_clipboard_image.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_clipboard_paste.dart';

const _png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/// A 2x1 24-bit .bmp, the shape the Windows channel builds from a packed DIB.
Uint8List _bmp() {
  final data = ByteData(62);
  data
    ..setUint8(0, 0x42)
    ..setUint8(1, 0x4D)
    ..setUint32(2, 62, Endian.little)
    ..setUint32(10, 54, Endian.little)
    ..setUint32(14, 40, Endian.little)
    ..setInt32(18, 2, Endian.little)
    ..setInt32(22, 1, Endian.little)
    ..setUint16(26, 1, Endian.little)
    ..setUint16(28, 24, Endian.little)
    ..setUint32(34, 8, Endian.little);
  // One row: a red and a blue pixel (BGR), padded to four bytes.
  final pixels = [0, 0, 255, 255, 0, 0, 0, 0];
  for (var i = 0; i < pixels.length; i++) {
    data.setUint8(54 + i, pixels[i]);
  }
  return data.buffer.asUint8List();
}

void main() {
  testWidgets('a bitmap is re-encoded as PNG', (tester) async {
    final out = await tester.runAsync(() => clipboardImageAsPng(_bmp()));
    expect(out!.sublist(0, 8), _png);
  });

  testWidgets('PNG bytes pass through untouched', (tester) async {
    final png = Uint8List.fromList([..._png, 1, 2, 3]);
    final out = await tester.runAsync(() => clipboardImageAsPng(png));
    expect(identical(out, png), isTrue);
  });

  testWidgets('bytes that are no image say the clipboard image is unreadable', (
    tester,
  ) async {
    Object? error;
    await tester.runAsync(() async {
      try {
        await clipboardImageAsPng(Uint8List.fromList([1, 2, 3, 4]));
      } on ClipboardImageReadException catch (e) {
        error = e;
      }
    });
    expect(error, isA<ClipboardImageReadException>());
  });
}
