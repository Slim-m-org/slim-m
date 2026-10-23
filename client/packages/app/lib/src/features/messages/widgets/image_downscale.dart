// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Shrinking a picked image before upload, shared by the avatar crop and the
/// space banner and icon.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:slimm_api/api.dart' show AppLog, LogTag;

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
  } catch (error, stack) {
    AppLog.swallowed(
      LogTag.media,
      'Could not shrink an image; using the original',
      error,
      stack,
    );
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
    final size = _fitToEdge(source.width, source.height, edge);
    final shrunk = await minifiedPng(
      bytes,
      width: size.width,
      height: size.height,
    );
    if (shrunk == null) return bytes;
    if (shrunk.length <= maxBytes || edge <= _minEdge) return shrunk;
    edge = (edge * 0.75).round();
  }
}

({int width, int height}) _fitToEdge(int width, int height, int edge) {
  if (width >= height) {
    return (width: edge, height: (edge * height / width).round());
  }
  return (width: (edge * width / height).round(), height: edge);
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
  } catch (error, stack) {
    AppLog.swallowed(
      LogTag.media,
      'Could not decode an image to shrink it; using the original',
      error,
      stack,
    );
    return null;
  }
}

/// What to tell someone whose pick [canDecodeImage] rejected.
const unreadableImageMessage =
    'That image format is not supported. Try a JPEG or PNG.';

/// Whether the engine can decode [bytes] at all, which a HEIC or truncated pick can fail.
Future<bool> canDecodeImage(Uint8List bytes) async =>
    await _decoded(bytes) != null;
