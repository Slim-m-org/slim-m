// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Decoding a picture for a tile it covers, sized by its shorter side.
///
/// `Image.memory`'s `cacheWidth` fixes the width, so a landscape photo in a
/// square cover tile decodes shorter than the tile and is stretched back up.
library;

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// The decode size that makes the shorter side of a [width] x [height] picture
/// [edge] pixels, or null to keep its own size when that is already smaller.
ui.TargetImageSize? coverTargetSize(int width, int height, int edge) {
  final shorter = width < height ? width : height;
  if (shorter <= edge) return null;
  final scale = edge / shorter;
  return ui.TargetImageSize(
    width: (width * scale).round().clamp(edge, width),
    height: (height * scale).round().clamp(edge, height),
  );
}

/// [source] decoded so its shorter side is [edge] pixels, never upscaled.
@immutable
class CoverResizeImage extends ImageProvider<CoverResizeImage> {
  const CoverResizeImage(this.source, {required this.edge});

  final MemoryImage source;
  final int edge;

  @override
  Future<CoverResizeImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<CoverResizeImage>(this);

  @override
  ImageStreamCompleter loadImage(
    CoverResizeImage key,
    ImageDecoderCallback decode,
  ) {
    Future<ui.Codec> resized(
      ui.ImmutableBuffer buffer, {
      ui.TargetImageSizeCallback? getTargetSize,
    }) => decode(
      buffer,
      getTargetSize: (width, height) =>
          coverTargetSize(width, height, edge) ??
          ui.TargetImageSize(width: width, height: height),
    );
    return source.loadImage(source, resized);
  }

  @override
  bool operator ==(Object other) =>
      other is CoverResizeImage && other.source == source && other.edge == edge;

  @override
  int get hashCode => Object.hash(source, edge);
}
