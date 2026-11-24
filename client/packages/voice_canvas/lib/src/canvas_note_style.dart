// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How a note is dressed: its fill, how much of the fill shows, its text colour and text step.
///
/// Every field is optional and absent means the look every note had before styles existed.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'canvas_ink.dart';
import 'canvas_text_box.dart';

/// The fill opacity a note without `fill_opacity` has always had.
const double canvasNoteTintedOpacity = 0.18;
const double canvasNoteSolidOpacity = 1;
const double canvasNoteClearOpacity = 0;

/// The wire value that asks for a text colour picked by contrast.
const String canvasNoteAutoColor = 'auto';

const int _maxColourKeyLength = 32;

/// A note's text size next to the medium step, from the text box steps so the two never drift.
double canvasNoteSizeScale(String? size) =>
    (canvasTextFontSizes[size] ?? canvasTextFontSizes[canvasDefaultTextSize]!) /
    canvasTextFontSizes[canvasDefaultTextSize]!;

@immutable
class CanvasNoteStyle {
  const CanvasNoteStyle({
    this.fill,
    this.fillOpacity,
    this.color,
    this.size,
  });

  /// Reads the style keys of a note's props, ignoring any of the wrong type.
  factory CanvasNoteStyle.fromWire(Map<String, dynamic> props) {
    final opacity = props['fill_opacity'];
    final size = props['size'];
    return CanvasNoteStyle(
      fill: _colourOf(props['fill']),
      fillOpacity: opacity is num && opacity.isFinite
          ? opacity.toDouble().clamp(0.0, 1.0)
          : null,
      color: _colourOf(props['color']),
      size:
          size is String && canvasTextFontSizes.containsKey(size) ? size : null,
    );
  }

  /// A palette key or `#rrggbb`; null is the default.
  final String? fill;

  /// 0 to 1; null is [canvasNoteTintedOpacity].
  final double? fillOpacity;

  /// A palette key, `#rrggbb` or [canvasNoteAutoColor]; null picks by contrast.
  final String? color;

  /// A key of [canvasTextFontSizes]; null is the medium step.
  final String? size;

  bool get isDefault =>
      fill == null && fillOpacity == null && color == null && size == null;

  CanvasNoteStyle copyWith({
    String? Function()? fill,
    double? Function()? fillOpacity,
    String? Function()? color,
    String? Function()? size,
  }) =>
      CanvasNoteStyle(
        fill: fill == null ? this.fill : fill(),
        fillOpacity: fillOpacity == null ? this.fillOpacity : fillOpacity(),
        color: color == null ? this.color : color(),
        size: size == null ? this.size : size(),
      );

  /// Every key, null for the default, so an edit clears what the person reset.
  Map<String, Object?> toWire() => {
        'fill': fill,
        'fill_opacity': fillOpacity,
        'color': color,
        'size': size,
      };

  @override
  bool operator ==(Object other) =>
      other is CanvasNoteStyle &&
      other.fill == fill &&
      other.fillOpacity == fillOpacity &&
      other.color == color &&
      other.size == size;

  @override
  int get hashCode => Object.hash(fill, fillOpacity, color, size);
}

String? _colourOf(Object? raw) =>
    raw is String && raw.isNotEmpty && raw.length <= _maxColourKeyLength
        ? raw
        : null;

/// The least contrast ratio an automatic note ink keeps against what is behind it.
const double minNoteContrast = 4.5;

double _contrast(Color a, Color b) {
  final hi = math.max(a.computeLuminance(), b.computeLuminance());
  final lo = math.min(a.computeLuminance(), b.computeLuminance());
  return (hi + 0.05) / (lo + 0.05);
}

/// The colours a note is drawn with, so the board and the field typed into it agree.
@immutable
class NotePalette {
  const NotePalette({
    this.inkColors = const {},
    this.textInk = const Color(0xFF1A1A1A),
    this.boardBackground = const Color(0xFFFFFFFF),
    this.darkInk = const Color(0xFF1A1A1A),
    this.lightInk = const Color(0xFFF5F5F5),
  });

  /// Palette keys by name; a key absent here paints as the fallback.
  final Map<String, Color> inkColors;

  /// The theme's own text colour, which "auto" keeps while it reads on the fill.
  final Color textInk;

  /// What a translucent note sits on.
  final Color boardBackground;

  /// What "auto" falls back on when [textInk] cannot be read on a fill.
  final Color darkInk;
  final Color lightInk;

  Color fillOf(CanvasNoteStyle style, Color fallback) =>
      resolveCanvasInk(inkColors, style.fill, fallback);

  /// The fill over the board, as the eye sees it.
  Color behind(CanvasNoteStyle style, Color fallback) => Color.alphaBlend(
        fillOf(style, fallback).withValues(
          alpha: style.fillOpacity ?? canvasNoteTintedOpacity,
        ),
        boardBackground,
      );

  /// The colour a note's text paints in: the one it names, else the one that reads best on its fill.
  Color inkOf(CanvasNoteStyle style, Color fallbackFill) {
    final named = style.color;
    if (named != null && named != canvasNoteAutoColor) {
      return resolveCanvasInk(inkColors, named, textInk);
    }
    final behindFill = behind(style, fallbackFill);
    if (_contrast(textInk, behindFill) >= minNoteContrast) return textInk;
    return _contrast(darkInk, behindFill) >= _contrast(lightInk, behindFill)
        ? darkInk
        : lightInk;
  }

  @override
  bool operator ==(Object other) =>
      other is NotePalette &&
      mapEquals(other.inkColors, inkColors) &&
      other.textInk == textInk &&
      other.boardBackground == boardBackground &&
      other.darkInk == darkInk &&
      other.lightInk == lightInk;

  @override
  int get hashCode => Object.hash(
        Object.hashAllUnordered(
            inkColors.entries.map((e) => Object.hash(e.key, e.value))),
        textInk,
        boardBackground,
        darkInk,
        lightInk,
      );
}
