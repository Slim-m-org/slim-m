// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Picture stand-ins for the review suites: real png bytes of a colour wash,
/// so a grid of GIFs, favorites and Space emoji reads as a grid of pictures.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A colour that stays the same for one [seed], so a tile keeps its picture.
(int, int, int) tintOf(String seed) {
  final h = seed.codeUnits.fold<int>(7, (a, b) => (a * 31 + b) & 0xffff);
  return (80 + h % 140, 70 + (h ~/ 7) % 150, 90 + (h ~/ 13) % 140);
}

final _crcTable = List<int>.generate(256, (n) {
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

List<int> _chunk(String type, List<int> data) {
  final body = [...ascii.encode(type), ...data];
  final length = ByteData(4)..setUint32(0, data.length);
  final crc = ByteData(4)..setUint32(0, _crc(body));
  return [...length.buffer.asUint8List(), ...body, ...crc.buffer.asUint8List()];
}

/// A real png of [w] by [h]: a diagonal wash of one colour, so a grid of
/// them reads as a grid of different pictures.
Uint8List tilePng(int w, int h, (int, int, int) rgb) {
  final raw = BytesBuilder();
  for (var y = 0; y < h; y++) {
    raw.addByte(0);
    for (var x = 0; x < w; x++) {
      final t = 0.55 + 0.45 * ((x + y) / (w + h));
      raw.add([
        (rgb.$1 * t).round(),
        (rgb.$2 * t).round(),
        (rgb.$3 * t).round(),
        255,
      ]);
    }
  }
  final header = ByteData(13)
    ..setUint32(0, w)
    ..setUint32(4, h)
    ..setUint8(8, 8)
    ..setUint8(9, 6);
  return Uint8List.fromList([
    137, 80, 78, 71, 13, 10, 26, 10, //
    ..._chunk('IHDR', header.buffer.asUint8List()),
    ..._chunk('IDAT', ZLibCodec().encode(raw.toBytes())),
    ..._chunk('IEND', const []),
  ]);
}
