// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The pixel size a PNG, JPEG, GIF or WebP declares in its own header.
///
/// The web engine cannot read a size without decoding, so this is how a
/// sender-chosen picture is bounded before any bitmap is allocated.
library;

import 'dart:typed_data';

/// The width and height [bytes] declare, or null when the header is not one of
/// the four formats above or is cut short.
({int width, int height})? declaredImageSize(Uint8List bytes) {
  if (_has(bytes, const [0x89, 0x50, 0x4E, 0x47])) return _png(bytes);
  if (_has(bytes, const [0x47, 0x49, 0x46, 0x38])) return _gif(bytes);
  if (_has(bytes, const [0xFF, 0xD8, 0xFF])) return _jpeg(bytes);
  if (_has(bytes, const [0x52, 0x49, 0x46, 0x46]) &&
      _has(bytes, const [0x57, 0x45, 0x42, 0x50], 8)) {
    return _webp(bytes);
  }
  return null;
}

bool _has(Uint8List bytes, List<int> magic, [int offset = 0]) {
  if (bytes.length < offset + magic.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (bytes[offset + i] != magic[i]) return false;
  }
  return true;
}

int _be32(Uint8List b, int at) =>
    (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];

int _be16(Uint8List b, int at) => (b[at] << 8) | b[at + 1];

int _le16(Uint8List b, int at) => b[at] | (b[at + 1] << 8);

int _le24(Uint8List b, int at) => b[at] | (b[at + 1] << 8) | (b[at + 2] << 16);

({int width, int height})? _png(Uint8List b) {
  if (b.length < 24) return null;
  return (width: _be32(b, 16), height: _be32(b, 20));
}

({int width, int height})? _gif(Uint8List b) {
  if (b.length < 10) return null;
  return (width: _le16(b, 6), height: _le16(b, 8));
}

({int width, int height})? _jpeg(Uint8List b) {
  var at = 2;
  while (at + 4 <= b.length) {
    if (b[at] != 0xFF) return null;
    final marker = b[at + 1];
    if (marker == 0xFF) {
      at++;
      continue;
    }
    if (marker == 0xD8 ||
        marker == 0x01 ||
        (marker >= 0xD0 && marker <= 0xD7)) {
      at += 2;
      continue;
    }
    final length = _be16(b, at + 2);
    final isFrame =
        marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC;
    if (isFrame) {
      if (at + 9 > b.length) return null;
      return (width: _be16(b, at + 7), height: _be16(b, at + 5));
    }
    if (length < 2) return null;
    at += 2 + length;
  }
  return null;
}

({int width, int height})? _webp(Uint8List b) {
  if (b.length < 30) return null;
  if (_has(b, const [0x56, 0x50, 0x38, 0x20], 12)) {
    return (width: _le16(b, 26) & 0x3FFF, height: _le16(b, 28) & 0x3FFF);
  }
  if (_has(b, const [0x56, 0x50, 0x38, 0x4C], 12)) {
    final bits = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24);
    return (width: (bits & 0x3FFF) + 1, height: ((bits >> 14) & 0x3FFF) + 1);
  }
  if (_has(b, const [0x56, 0x50, 0x38, 0x58], 12)) {
    return (width: _le24(b, 24) + 1, height: _le24(b, 27) + 1);
  }
  return null;
}
