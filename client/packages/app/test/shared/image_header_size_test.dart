// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The header sniffer is what bounds a web decode before any bitmap exists.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/bounded_image_decode.dart';
import 'package:slimm_app/src/providers/image_header_size.dart';

Uint8List _png(int w, int h) {
  final b = Uint8List(33)
    ..setAll(0, const [0x89, 0x50, 0x4E, 0x47, 13, 10, 26, 10]);
  final d = ByteData.view(b.buffer);
  d.setUint32(8, 13);
  b.setAll(12, 'IHDR'.codeUnits);
  d.setUint32(16, w);
  d.setUint32(20, h);
  return b;
}

Uint8List _gif(int w, int h) {
  final b = Uint8List(13)..setAll(0, 'GIF89a'.codeUnits);
  ByteData.view(b.buffer)
    ..setUint16(6, w, Endian.little)
    ..setUint16(8, h, Endian.little);
  return b;
}

Uint8List _jpeg(int w, int h) {
  final b = BytesBuilder()
    ..add(const [0xFF, 0xD8])
    ..add(const [0xFF, 0xE0, 0x00, 0x04, 0x00, 0x00])
    ..add([
      0xFF,
      0xC0,
      0x00,
      0x0B,
      8,
      h >> 8,
      h & 255,
      w >> 8,
      w & 255,
      1,
      1,
      0x11,
      0,
    ]);
  return b.toBytes();
}

Uint8List _webp(String fourcc, void Function(Uint8List) fill) {
  final b = Uint8List(40)
    ..setAll(0, 'RIFF'.codeUnits)
    ..setAll(8, 'WEBP'.codeUnits)
    ..setAll(12, fourcc.codeUnits);
  fill(b);
  return b;
}

void main() {
  test('reads PNG, GIF and JPEG dimensions', () {
    expect(declaredImageSize(_png(30000, 40000)), (
      width: 30000,
      height: 40000,
    ));
    expect(declaredImageSize(_gif(640, 480)), (width: 640, height: 480));
    expect(declaredImageSize(_jpeg(8000, 6000)), (width: 8000, height: 6000));
  });

  test('reads the three WebP variants', () {
    final lossy = _webp(
      'VP8 ',
      (b) => ByteData.view(b.buffer)
        ..setUint16(26, 1200, Endian.little)
        ..setUint16(28, 800, Endian.little),
    );
    expect(declaredImageSize(lossy), (width: 1200, height: 800));
    final lossless = _webp('VP8L', (b) {
      const bits = (4000 - 1) | ((3000 - 1) << 14);
      ByteData.view(b.buffer).setUint32(21, bits, Endian.little);
    });
    expect(declaredImageSize(lossless), (width: 4000, height: 3000));
    final extended = _webp('VP8X', (b) {
      b[24] = (9000 - 1) & 255;
      b[25] = ((9000 - 1) >> 8) & 255;
      b[27] = (7000 - 1) & 255;
      b[28] = ((7000 - 1) >> 8) & 255;
    });
    expect(declaredImageSize(extended), (width: 9000, height: 7000));
  });

  test('is null for unknown or truncated bytes', () {
    expect(declaredImageSize(Uint8List.fromList(const [1, 2, 3])), isNull);
    expect(declaredImageSize(_png(1, 1).sublist(0, 20)), isNull);
    expect(
      declaredImageSize(Uint8List.fromList(const [0xFF, 0xD8, 0xFF])),
      isNull,
    );
  });

  test(
    'the web decode refuses an oversized header without decoding it',
    () async {
      await expectLater(
        decodeBoundedViaPostDecodeCheck(
          _png(30000, 40000),
          100,
          kMaxDeclaredPixels,
        ),
        throwsA(isA<ImageTooLargeException>()),
      );
    },
  );
}
