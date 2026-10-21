// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A valid PNG that declares a huge pixel size yet compresses to a small payload.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

int _crc(List<int> data) {
  var c = 0xFFFFFFFF;
  for (final b in data) {
    c ^= b;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
    }
  }
  return c ^ 0xFFFFFFFF;
}

List<int> _chunk(String type, List<int> body) {
  final head = ascii.encode(type) + body;
  final out = ByteData(4)..setUint32(0, body.length);
  final crc = ByteData(4)..setUint32(0, _crc(head));
  return [...out.buffer.asUint8List(), ...head, ...crc.buffer.asUint8List()];
}

/// A valid all-black 8-bit grayscale PNG of 64 MP that compresses to a
/// small payload.
Uint8List pixelBombPng(int side) {
  final ihdr = ByteData(13)
    ..setUint32(0, side)
    ..setUint32(4, side)
    ..setUint8(8, 8)
    ..setUint8(9, 0);
  final row = Uint8List(side + 1);
  late final List<int> idat;
  final sink = ZLibEncoder().startChunkedConversion(
    ByteConversionSink.withCallback((bytes) => idat = bytes),
  );
  for (var y = 0; y < side; y++) {
    sink.add(row);
  }
  sink.close();
  return Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
    ..._chunk('IHDR', ihdr.buffer.asUint8List()),
    ..._chunk('IDAT', idat),
    ..._chunk('IEND', const []),
  ]);
}
