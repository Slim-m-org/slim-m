// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The numbers behind a personal background picture: how far panes let it
/// through, and how much it must fade so text on a pane stays AA.
///
/// Contrast is measured against the picture's own darkest and lightest
/// pixels, or against pure black and white when those are not known.
library;

import 'dart:math' as math;
import 'dart:ui' show Color;

import 'app_tokens.dart';
import 'colour_contrast.dart';

/// How opaque a pane's own surface stays over the picture; the rest shows it.
const double kBackgroundPaneAlpha = 0.5;

/// The fade the picture starts at, before a person moves it.
const double kBackgroundDefaultDim = 0.7;

/// The fade is never set below this, whatever the slider range says.
const double kBackgroundMaxDim = 0.95;

/// The smallest ratio WCAG AA asks of body text.
const double kBackgroundTextRatio = 4.5;

/// The darkest and lightest pixel of a picture, which bound what text over it
/// can ever sit on.
class PictureRange {
  const PictureRange(this.darkest, this.lightest);

  /// Black and white: what any picture could contain, so the safe default.
  static const worst = PictureRange(Color(0xFF000000), Color(0xFFFFFFFF));

  final Color darkest;
  final Color lightest;
}

/// [surface] as a pane paints it, over a picture pixel [picture] faded
/// toward [tokens]'s base surface by [dim].
Color paneOverPicture(
  AppTokens tokens,
  Color surface,
  Color picture,
  double dim,
) {
  final faded = Color.lerp(picture, tokens.surfaceBase, dim)!;
  return Color.alphaBlend(
    surface.withValues(alpha: kBackgroundPaneAlpha),
    faded,
  );
}

/// The lowest contrast [text] reaches on a pane of [surface] at fade [dim],
/// over the extremes of [range].
double worstPaneContrast(
  AppTokens tokens,
  Color text,
  Color surface,
  double dim, [
  PictureRange range = PictureRange.worst,
]) {
  var worst = double.infinity;
  for (final picture in [range.darkest, range.lightest]) {
    final under = paneOverPicture(tokens, surface, picture, dim);
    worst = math.min(worst, contrastRatio(text, under));
  }
  return worst;
}

/// The two text roles and two pane surfaces a picture sits under.
List<(Color text, Color surface)> _readingPairs(AppTokens t) => [
      (t.textPrimary, t.surfaceBase),
      (t.textPrimary, t.surfaceSunken),
      (t.textSecondary, t.surfaceBase),
      (t.textSecondary, t.surfaceSunken),
    ];

/// The least fade that keeps every reading pair of [tokens] at AA over the
/// worst picture, or as close as the theme itself allows when a pair is
/// already under AA with no picture at all.
double minimumBackgroundDim(
  AppTokens tokens, [
  PictureRange range = PictureRange.worst,
]) {
  var floor = 0.0;
  for (final (text, surface) in _readingPairs(tokens)) {
    final need = math.min(kBackgroundTextRatio, contrastRatio(text, surface));
    floor = math.max(floor, _dimFor(tokens, text, surface, need, range));
  }
  return floor;
}

double _dimFor(
  AppTokens tokens,
  Color text,
  Color surface,
  double need,
  PictureRange range,
) {
  if (worstPaneContrast(tokens, text, surface, 0, range) >= need) return 0;
  var lo = 0.0;
  var hi = 1.0;
  for (var i = 0; i < 24; i++) {
    final mid = (lo + hi) / 2;
    if (worstPaneContrast(tokens, text, surface, mid, range) >= need) {
      hi = mid;
    } else {
      lo = mid;
    }
  }
  return hi;
}

/// [wanted] raised to [tokens]'s floor and held under [kBackgroundMaxDim].
double effectiveBackgroundDim(
  AppTokens tokens,
  double wanted, [
  PictureRange range = PictureRange.worst,
]) =>
    math.min(
      kBackgroundMaxDim,
      math.max(wanted, minimumBackgroundDim(tokens, range)),
    );
