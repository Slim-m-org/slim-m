// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where the pieces of one avatar sit, as pure arithmetic on its diameter.
///
/// Kept apart from the widget so a test can assert the rule at every
/// [AppAvatarSize] without painting: the initials never touch the ring or the
/// presence dot, whatever the size.
library;

import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';

/// The layout of an avatar of one [size], in the avatar's own coordinates
/// (origin at its top-left corner).
@immutable
class AppAvatarGeometry {
  const AppAvatarGeometry(this.size, {this.phone = false});

  final double size;

  /// Whether the presence mark is the phone glyph rather than the dot, which
  /// needs a few more pixels to read.
  final bool phone;

  /// A caller-supplied ring's stroke, drawn inside the avatar's edge.
  static const double ringWidth = 2;

  /// The surface-coloured halo around the dot that separates it from the
  /// picture.
  static const double dotHalo = 1.5;

  static const double _minDot = 8;
  static const double _phoneExtra = 4;
  static const double _dotShare = 0.3;
  static const double _initialsShare = 0.36;
  static const double _minInitials = 9;

  /// Two monospaced initials are this much wider than they are tall.
  static const double _initialsAspect = 1.2;

  /// Clear space kept between the initials' box and the dot's halo.
  static const double _clearance = 1;

  double get radius => size / 2;

  double get dotDiameter =>
      math.max(_minDot, (size * _dotShare).roundToDouble());

  /// The presence mark's box: [dotDiameter], or a little more for the phone.
  double get markDiameter => dotDiameter + (phone ? _phoneExtra : 0);

  double get dotHaloRadius => markDiameter / 2 + dotHalo;

  /// On the avatar's edge at the bottom-right diagonal, nudged outward so the
  /// dot reads as attached to the picture rather than sitting on it.
  Offset get dotCenter {
    final distance = radius + dotHaloRadius * 0.2;
    final axis = radius + distance / math.sqrt2;
    return Offset(axis, axis);
  }

  /// The size the initials are asked to be before they are scaled to fit
  /// [initialsBox].
  double get initialsFontSize =>
      math.max(_minInitials, (size * _initialsShare).roundToDouble());

  /// The largest box centred in the avatar that the initials may occupy:
  /// inside the ring, and clear of the dot when there is one.
  Size initialsBox({required bool withDot}) {
    final reach = radius - ringWidth;
    final shrink = math.sqrt(1 + 1 / (_initialsAspect * _initialsAspect));
    var halfWidth = reach / shrink;
    if (withDot) {
      final dot = dotCenter - Offset(radius, radius);
      final keepOut = dotHaloRadius + _clearance;
      while (halfWidth > 0 &&
          (Offset(halfWidth, halfWidth / _initialsAspect) - dot).distance <
              keepOut) {
        halfWidth -= 0.1;
      }
    }
    final width = math.max(0.0, halfWidth * 2);
    return Size(width, width / _initialsAspect);
  }
}
