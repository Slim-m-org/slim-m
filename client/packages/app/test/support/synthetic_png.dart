// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Real png bytes of any declared size, built without decoding anything, so a
/// test can hand a decoder a huge image cheaply or a tiny file that claims to
/// be huge.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

final List<int> _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc(List<int> data) {
  var c = 0xffffffff;
  for (final b in data) {
    c = _crcTable[(c ^ b) & 0xff] ^ (c >> 8);
  }
  return c ^ 0xffffffff;
}

Uint8List _u32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v);

List<int> _chunk(String type, List<int> data) {
  final body = [...ascii.encode(type), ...data];
  return [..._u32(data.length), ...body, ..._u32(_crc(body))];
}

Uint8List _png(int w, int h, List<int> header, Uint8List raw) {
  return Uint8List.fromList([
    137, 80, 78, 71, 13, 10, 26, 10, //
    ..._chunk('IHDR', [..._u32(w), ..._u32(h), ...header]),
    ..._chunk('IDAT', ZLibCodec().encode(raw)),
    ..._chunk('IEND', const []),
  ]);
}

/// An opaque 8-bit rgba png, [w] by [h]; decodes to exactly that size.
Uint8List solidPng(int w, int h) {
  final raw = Uint8List((w * 4 + 1) * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      raw[y * (w * 4 + 1) + 1 + x * 4 + 3] = 255;
    }
  }
  return _png(w, h, [8, 6, 0, 0, 0], raw);
}

/// A 1-bit grayscale png of all-zero rows: a few KB however large [w] x [h]
/// is, which is what lets a small payload declare a huge bitmap.
Uint8List blankBilevelPng(int w, int h) {
  final raw = Uint8List(((w + 7) ~/ 8 + 1) * h);
  return _png(w, h, [1, 0, 0, 0, 0], raw);
}
