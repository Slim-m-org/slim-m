// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Shrinking a picked picture to what the background keeps, and reading its
/// tonal range so the fade needed for readable text is not worst-case.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart' show Color;
import 'package:slimm_api/api.dart' show AppLog, LogTag;
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/bounded_image_decode.dart';

/// The side of the thumbnail the range is read from; the decoder averages
/// areas down to it, so a single bright speck does not set the range.
const _toneSide = 48;

class PreparedBackground {
  const PreparedBackground(this.png, this.range);

  final Uint8List png;
  final PictureRange range;
}

/// [bytes] decoded no larger than [maxSide] and re-encoded, with the range of
/// the result. Null when it cannot be decoded, is too large, or is blank.
Future<PreparedBackground?> prepareBackground(
  Uint8List bytes, {
  required int maxSide,
  required int maxSourcePixels,
}) async {
  ui.Image? image;
  try {
    image = await decodeBoundedImage(
      bytes,
      maxSide: maxSide,
      maxSourcePixels: maxSourcePixels,
    );
    final png = (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))?.buffer.asUint8List();
    if (png == null) return null;
    final range = await _rangeOf(image);
    return range == null ? null : PreparedBackground(png, range);
  } catch (error, stack) {
    AppLog.swallowed(
      LogTag.media,
      'Could not read the picked background picture',
      error,
      stack,
    );
    return null;
  } finally {
    image?.dispose();
  }
}

Future<PictureRange?> _rangeOf(ui.Image image) async {
  final recorder = ui.PictureRecorder();
  final longer = image.width > image.height ? image.width : image.height;
  final scale = _toneSide / longer;
  final w = (image.width * scale).ceil().clamp(1, _toneSide);
  final h = (image.height * scale).ceil().clamp(1, _toneSide);
  ui.Canvas(recorder).drawImageRect(
    image,
    ui.Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
    ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..filterQuality = ui.FilterQuality.medium,
  );
  final picture = recorder.endRecording();
  final small = await picture.toImage(w, h);
  picture.dispose();
  try {
    final rgba = (await small.toByteData())?.buffer.asUint8List();
    return rgba == null ? null : rangeOfRgba(rgba);
  } finally {
    small.dispose();
  }
}

/// The darkest and lightest opaque pixel in [rgba], by luminance.
PictureRange? rangeOfRgba(Uint8List rgba) {
  Color? darkest;
  Color? lightest;
  for (var i = 0; i + 3 < rgba.length; i += 4) {
    if (rgba[i + 3] < 8) continue;
    final c = Color.fromARGB(255, rgba[i], rgba[i + 1], rgba[i + 2]);
    final l = c.computeLuminance();
    if (darkest == null || l < darkest.computeLuminance()) darkest = c;
    if (lightest == null || l > lightest.computeLuminance()) lightest = c;
  }
  if (darkest == null || lightest == null) return null;
  return PictureRange(darkest, lightest);
}

List<String> rangeToStrings(PictureRange r) => [
  '${r.darkest.toARGB32()}',
  '${r.lightest.toARGB32()}',
];

/// Falls back to the worst case when the stored value is unusable.
PictureRange rangeFromStrings(List<String> stored) {
  if (stored.length != 2) return PictureRange.worst;
  final a = int.tryParse(stored[0]);
  final b = int.tryParse(stored[1]);
  if (a == null || b == null) return PictureRange.worst;
  return PictureRange(Color(a), Color(b));
}
