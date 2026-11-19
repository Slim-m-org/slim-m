// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Bakes a stamp into the one bitmap every surface draws it from (decision
/// 0121): a tile, the board and, as a PNG, the overlay runner.
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:slimm_design_system/design_system.dart' show AppFonts;

/// Pixels on a baked stamp's longest side.
const stampBakeEdge = 512;

/// How much of the square a standard emoji's glyph fills, leaving room for a colour glyph's overhang.
const _glyphFill = 0.8;

/// [glyph] drawn with the colour emoji fonts, centred in an [edge] square.
Future<ui.Image> bakeEmojiGlyph(String glyph, {int edge = stampBakeEdge}) {
  final side = edge.toDouble();
  final paragraph =
      (ui.ParagraphBuilder(
              ui.ParagraphStyle(
                textAlign: ui.TextAlign.center,
                maxLines: 1,
                fontSize: side * _glyphFill,
                height: 1,
              ),
            )
            ..pushStyle(
              ui.TextStyle(
                fontFamilyFallback: AppFonts.emoji,
                fontSize: side * _glyphFill,
                color: const ui.Color(0xFF000000),
              ),
            )
            ..addText(glyph))
          .build()
        ..layout(ui.ParagraphConstraints(width: side));
  final recorder = ui.PictureRecorder();
  ui.Canvas(
    recorder,
  ).drawParagraph(paragraph, ui.Offset(0, (side - paragraph.height) / 2));
  return _imageOf(recorder, edge, edge);
}

/// The recording as an image; the picture is disposed once the image exists.
Future<ui.Image> _imageOf(
  ui.PictureRecorder recorder,
  int width,
  int height,
) async {
  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width, height);
  } finally {
    picture.dispose();
  }
}

/// [source] scaled so its longest side is [edge], keeping its shape.
Future<ui.Image> bakeScaled(ui.Image source, {int edge = stampBakeEdge}) {
  final k = edge / math.max(source.width, source.height);
  final width = math.max(1, (source.width * k).round());
  final height = math.max(1, (source.height * k).round());
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawImageRect(
    source,
    ui.Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..filterQuality = ui.FilterQuality.high,
  );
  return _imageOf(recorder, width, height);
}

/// [image] as the PNG the overlay runner decodes.
Future<Uint8List> encodeStampPng(ui.Image image) async {
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  if (png == null) throw StateError('A stamp did not encode.');
  return png.buffer.asUint8List();
}
