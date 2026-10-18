// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether bytes can animate is read from the bytes, because the content type
/// of a webp or png says nothing about frames.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/providers/attachment_preview_bytes.dart';

Uint8List _len(int n, Endian e) =>
    (ByteData(4)..setUint32(0, n, e)).buffer.asUint8List();

/// PNG: length, type, data, crc.
Uint8List _pngChunk(String type, List<int> data) => Uint8List.fromList([
  ..._len(data.length, Endian.big),
  ...ascii.encode(type),
  ...data,
  0,
  0,
  0,
  0,
]);

/// RIFF: type, length, data.
Uint8List _riffChunk(String type, List<int> data) => Uint8List.fromList([
  ...ascii.encode(type),
  ..._len(data.length, Endian.little),
  ...data,
]);

Uint8List _png(List<String> chunks) => Uint8List.fromList([
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  for (final c in chunks) ..._pngChunk(c, List.filled(8, 0)),
]);

Uint8List _webp(List<String> chunks) {
  final body = [
    ...ascii.encode('WEBP'),
    for (final c in chunks) ..._riffChunk(c, List.filled(6, 0)),
  ];
  return Uint8List.fromList([
    ...ascii.encode('RIFF'),
    ...(ByteData(
      4,
    )..setUint32(0, body.length, Endian.little)).buffer.asUint8List(),
    ...body,
  ]);
}

void main() {
  test('a gif animates', () {
    expect(looksAnimated(Uint8List.fromList(ascii.encode('GIF89a....'))), true);
  });

  test('a png with an acTL chunk before its data animates', () {
    expect(looksAnimated(_png(['IHDR', 'acTL', 'IDAT', 'IEND'])), isTrue);
  });

  test('a png without acTL is a still, even with acTL-looking data later', () {
    expect(looksAnimated(_png(['IHDR', 'IDAT', 'acTL'])), isFalse);
  });

  test('a webp with an ANIM chunk animates', () {
    expect(looksAnimated(_webp(['VP8X', 'ANIM', 'ANMF'])), isTrue);
  });

  test('a still webp does not', () {
    expect(looksAnimated(_webp(['VP8X', 'VP8 '])), isFalse);
  });

  test('truncated or foreign bytes do not', () {
    expect(looksAnimated(Uint8List(0)), isFalse);
    expect(looksAnimated(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47])), false);
    expect(looksAnimated(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0])), false);
  });
}
