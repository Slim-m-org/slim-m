// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Shrinking a picked image before upload, shared by the avatar crop and the
/// space banner and icon.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

/// [png] resampled so its width is [width], keeping the aspect ratio, or
/// square when [height] is given.
///
/// The decoder's own downscale is area-averaging, which keeps detail a canvas
/// minification (a bilinear tap) throws away. Null when it cannot be decoded.
Future<Uint8List?> minifiedPng(
  Uint8List png, {
  required int width,
  int? height,
}) async {
  try {
    final codec = await ui.instantiateImageCodec(
      png,
      targetWidth: width,
      targetHeight: height,
    );
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    frame.image.dispose();
    codec.dispose();
    return data?.buffer.asUint8List();
  } catch (_) {
    // Null is the documented fallback; a throw must not become a cancel.
    return null;
  }
}

/// [bytes] unchanged when the picture already fits [maxEdge] on its longer
/// side and [maxBytes] in size, otherwise a PNG shrunk to fit both.
///
/// Anything it cannot decode, and an animation (which a single frame would
/// flatten), goes through untouched so the server alone decides.
Future<Uint8List> downscaledToFit(
  Uint8List bytes, {
  required int maxEdge,
  required int maxBytes,
}) async {
  final source = await _decoded(bytes);
  if (source == null || source.animated) return bytes;
  final longer = source.width > source.height ? source.width : source.height;
  if (longer <= maxEdge && bytes.length <= maxBytes) return bytes;
  var edge = longer < maxEdge ? longer : maxEdge;
  while (true) {
    final landscape = source.width >= source.height;
    final shrunk = await minifiedPng(
      bytes,
      width: landscape ? edge : (edge * source.width / source.height).round(),
      height: landscape ? (edge * source.height / source.width).round() : edge,
    );
    if (shrunk == null) return bytes;
    if (shrunk.length <= maxBytes || edge <= _minEdge) return shrunk;
    edge = (edge * 0.75).round();
  }
}

/// Below this a picture is no use to anyone, so shrinking stops.
const int _minEdge = 256;

Future<({int width, int height, bool animated})?> _decoded(
  Uint8List bytes,
) async {
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final result = (
      width: frame.image.width,
      height: frame.image.height,
      animated: codec.frameCount > 1,
    );
    frame.image.dispose();
    codec.dispose();
    return result;
  } catch (_) {
    return null;
  }
}
