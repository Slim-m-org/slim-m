// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tiny PNGs whose header declares a size their few bytes cannot back.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A PNG of a few dozen bytes that declares [width] x [height] pixels.
Uint8List declaredSizePng(int width, int height) {
  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8)
    ..setUint8(9, 0);
  final out = BytesBuilder()
    ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    ..add(_chunk('IHDR', header.buffer.asUint8List()))
    ..add(_chunk('IDAT', zlib.encode(const [0, 0])))
    ..add(_chunk('IEND', const []));
  return out.toBytes();
}

/// A well-formed [width] x [height] PNG of one grey value, a few hundred KB
/// when large because a solid fill compresses to almost nothing.
Uint8List solidPng(int width, int height) {
  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8)
    ..setUint8(9, 0);
  final row = Uint8List(width + 1);
  final rows = BytesBuilder();
  final encoder = ZLibEncoder().startChunkedConversion(
    ByteConversionSink.withCallback(rows.add),
  );
  for (var y = 0; y < height; y++) {
    encoder.add(row);
  }
  encoder.close();
  return (BytesBuilder()
        ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        ..add(_chunk('IHDR', header.buffer.asUint8List()))
        ..add(_chunk('IDAT', rows.toBytes()))
        ..add(_chunk('IEND', const [])))
      .toBytes();
}

Uint8List _chunk(String type, List<int> data) {
  final body = [...ascii.encode(type), ...data];
  final out = ByteData(12 + data.length);
  out.setUint32(0, data.length);
  final bytes = out.buffer.asUint8List()..setRange(4, 4 + body.length, body);
  out.setUint32(8 + data.length, _crc32(body));
  return bytes;
}

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc ^= b;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}
