// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Photo-like png bytes the messages review suites hand to the attachment
/// providers, so a gallery tile shows a picture and not a flat grey square.
///
/// Built without the engine (a gradient, a sun and a ridge, deflated by hand),
/// which keeps them synchronous and the same on every machine.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:slimm_api/api.dart' as api;

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

/// A [w] by [h] landscape: [sky] and [ground] are `0xRRGGBB` blends, and the
/// sun sits at [sun] (0 to 1 across the frame).
Uint8List landscapePng(
  int w,
  int h, {
  required int sky,
  required int ground,
  double sun = 0.7,
}) {
  int channel(int rgb, int shift) => (rgb >> shift) & 0xff;
  final raw = Uint8List((w * 4 + 1) * h);
  for (var y = 0; y < h; y++) {
    final row = y * (w * 4 + 1);
    for (var x = 0; x < w; x++) {
      final t = y / h;
      final ridge =
          0.62 + 0.08 * math.sin(x / w * 7.0) + 0.04 * math.sin(x / w * 19);
      final dx = x / w - sun;
      final dy = (y / h - 0.34) * h / w;
      final inSun = dx * dx + dy * dy < 0.0035;
      final base = t > ridge ? ground : sky;
      final k = t > ridge ? (t - ridge) / (1 - ridge) : t / ridge;
      final at = row + 1 + x * 4;
      for (var c = 0; c < 3; c++) {
        final v = channel(base, 16 - 8 * c).toDouble();
        final shaded = t > ridge ? v * (1 - 0.45 * k) : v * (0.55 + 0.45 * k);
        raw[at + c] = (inSun ? 250 : shaded).round().clamp(0, 255);
      }
      raw[at + 3] = 255;
    }
  }
  return Uint8List.fromList([
    137, 80, 78, 71, 13, 10, 26, 10, //
    ..._chunk('IHDR', [..._u32(w), ..._u32(h), 8, 6, 0, 0, 0]),
    ..._chunk('IDAT', ZLibCodec().encode(raw)),
    ..._chunk('IEND', const []),
  ]);
}

/// Four different pictures, so a gallery tile can be told from its neighbour.
Uint8List photo(int index, {int w = 640, int h = 420}) => switch (index % 4) {
  0 => landscapePng(w, h, sky: 0xf3a65a, ground: 0x2f5d50, sun: 0.72),
  1 => landscapePng(w, h, sky: 0x5aa0d6, ground: 0x3d6b3a, sun: 0.28),
  2 => landscapePng(w, h, sky: 0xb98ad9, ground: 0x203a5c, sun: 0.5),
  _ => landscapePng(w, h, sky: 0xe9d36b, ground: 0x7a4b2a, sun: 0.85),
};

api.Attachment imageAttachment(
  String id,
  String filename, {
  int size = 184320,
}) => api.Attachment(
  id: id,
  filename: filename,
  contentType: 'image/png',
  size: size,
);
