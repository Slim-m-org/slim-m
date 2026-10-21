// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Custom [SliderTrackShape] and [SliderComponentShape] implementations for
/// [AppSlider], split out of that file to keep both under the review budget:
/// these are self-contained painting code with no state of their own.
library;

import 'package:flutter/material.dart';

import '../../app_metrics.dart';

/// Draws the trough (background, hairline border), an optional live
/// [meterFraction] behind everything, and either a filled active portion
/// (normal) or a 2px position line (`tall`), in that paint order, matching
/// the source design's DOM order exactly since later elements paint over
/// earlier ones.
class TroughTrackShape extends SliderTrackShape with BaseSliderTrackShape {
  const TroughTrackShape({
    required this.tall,
    required this.trackColor,
    required this.borderColor,
    required this.fillColor,
    required this.meterColor,
    required this.meterFraction,
    this.quietColor,
    this.hearColor,
  });

  final bool tall;
  final Color trackColor;
  final Color borderColor;
  final Color fillColor;
  final Color meterColor;
  final double? meterFraction;

  /// With both set, the `tall` trough is two tones split at the thumb: quiet before it, heard after.
  final Color? quietColor;
  final Color? hearColor;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {
    final trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final canvas = context.canvas;
    final radius =
        Radius.circular(tall ? AppRadii.control : trackRect.height / 2);
    final rrect = RRect.fromRectAndRadius(trackRect, radius);

    canvas.drawRRect(rrect, Paint()..color = trackColor);

    canvas.save();
    canvas.clipRRect(rrect);

    final quiet = quietColor;
    final hear = hearColor;
    if (tall && quiet != null && hear != null) {
      canvas.drawRect(
        Rect.fromLTRB(
          trackRect.left,
          trackRect.top,
          thumbCenter.dx,
          trackRect.bottom,
        ),
        Paint()..color = quiet,
      );
      canvas.drawRect(
        Rect.fromLTRB(
          thumbCenter.dx,
          trackRect.top,
          trackRect.right,
          trackRect.bottom,
        ),
        Paint()..color = hear,
      );
    }

    final meterFraction = this.meterFraction;
    if (meterFraction != null && meterFraction > 0) {
      final meterRect = Rect.fromLTWH(
        trackRect.left,
        trackRect.top,
        trackRect.width * meterFraction,
        trackRect.height,
      );
      canvas.drawRect(meterRect, Paint()..color = meterColor);
    }

    if (!tall) {
      final fillRect = Rect.fromLTRB(
          trackRect.left, trackRect.top, thumbCenter.dx, trackRect.bottom);
      canvas.drawRect(fillRect, Paint()..color = fillColor);
    } else {
      final lineRect =
          Rect.fromLTWH(thumbCenter.dx - 1, trackRect.top, 2, trackRect.height);
      canvas.drawRect(lineRect, Paint()..color = fillColor);
    }

    canvas.restore();

    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = borderColor,
    );
  }
}

/// A round 14px thumb (normal) or a 12px-wide, trough-height rounded-rect
/// thumb (`tall`). The source design draws the tall thumb 8px taller than
/// the trough and relies on the trough's own overflow:hidden to crop it back
/// down; painting it at exactly the trough height is the same result
/// without reproducing that clip.
class TroughThumbShape extends SliderComponentShape {
  const TroughThumbShape({
    required this.tall,
    required this.trackHeight,
    required this.color,
    required this.borderColor,
  });

  final bool tall;
  final double trackHeight;
  final Color color;
  final Color borderColor;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) {
    return tall ? Size(12, trackHeight) : const Size(14, 14);
  }

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final size = getPreferredSize(true, isDiscrete);
    final rect =
        Rect.fromCenter(center: center, width: size.width, height: size.height);
    final radius = Radius.circular(tall ? AppRadii.control : size.width / 2);
    final rrect = RRect.fromRectAndRadius(rect, radius);
    final canvas = context.canvas;

    canvas.drawRRect(rrect, Paint()..color = color);
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = borderColor,
    );
  }
}
