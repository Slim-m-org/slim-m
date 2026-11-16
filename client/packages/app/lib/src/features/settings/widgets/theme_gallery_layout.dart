// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The gallery grid's shape at a content width: how many columns, and each
/// card's width and height with its foot measured at the text scale.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'theme_miniature.dart';

/// Three cards across from this much content width, two below it.
const kThemeGalleryThreeColumnWidth = 480.0;
const kThemeGalleryGap = AppSpacing.s12;

const _footMin = 52.0;
const themeCardFootPadding = EdgeInsets.fromLTRB(
  AppSpacing.s12,
  AppSpacing.s8,
  AppSpacing.s8,
  AppSpacing.s8,
);

/// The grid's column count and each card's size at a content width.
class ThemeGalleryLayout {
  factory ThemeGalleryLayout(double width, TextScaler textScaler) {
    final columns = width >= kThemeGalleryThreeColumnWidth ? 3 : 2;
    final cardWidth = (width - kThemeGalleryGap * (columns - 1)) / columns;
    return ThemeGalleryLayout._(
      columns,
      cardWidth,
      cardWidth / ThemeMiniatureGeometry.aspect + 1 + _footHeight(textScaler),
    );
  }

  const ThemeGalleryLayout._(this.columns, this.cardWidth, this.cardHeight);

  final int columns;
  final double cardWidth;

  /// A card's full height: miniature, hairline and foot.
  final double cardHeight;
}

double _lineHeight(TextStyle style, TextScaler scaler) {
  final painter = TextPainter(
    text: TextSpan(text: 'Ag', style: style),
    textScaler: scaler,
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  final height = painter.height;
  painter.dispose();
  return height;
}

/// The foot measured at [scaler]: name, meta, and the 30 the trailing button takes.
double _footHeight(TextScaler scaler) {
  final name = _lineHeight(themeCardNameStyle, scaler);
  final meta = math.max(_lineHeight(AppText.caption, scaler), AppSizes.icon12);
  final text = name + 2 + meta;
  return math.max(
    _footMin,
    themeCardFootPadding.vertical + math.max(text, AppSizes.rowPointer),
  );
}

/// A card's name, which the foot is measured with.
final themeCardNameStyle = AppText.ui.copyWith(fontWeight: AppWeights.medium);
