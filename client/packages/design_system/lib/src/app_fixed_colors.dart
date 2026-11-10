// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Colours that stay the same in every theme.
library;

import 'package:flutter/painting.dart';

/// Colours for objects drawn on the Voice Canvas.
///
/// Deliberately warmer and more saturated than the chrome. The canvas is the
/// one place allowed more energy, and the energy is meant to come from the
/// content rather than from restyling the app around it.
///
/// [cursors] is a closed set of six categorical hues for remote participants.
/// They must not reuse the status hues or the accent, or a cursor reads as a
/// presence indicator.
abstract final class AppCanvasColors {
  static const Color annotation = Color(0xFFE86A5C);
  static const Color note = Color(0xFFE8B04B);
  static const Color shape = Color(0xFF5B8FD6);
  static const Color penGreen = Color(0xFF6FBF73);
  static const Color penPurple = Color(0xFF8C6FE0);
  static const Color penPink = Color(0xFFE0699A);

  static const List<Color> cursors = [
    Color(0xFFE0699A),
    Color(0xFF8C6FE0),
    Color(0xFF3FA9C9),
    Color(0xFFD98A3F),
    Color(0xFF6FBF73),
    Color(0xFFC96FB8),
  ];
}

/// A webhook or bot embed's colour, reduced server-side to one of six
/// swatches - painted only as a border stripe, never as text.
abstract final class AppEmbedAccents {
  static const Color red = Color(0xFFE0685C);
  static const Color orange = Color(0xFFD98A3F);
  static const Color yellow = Color(0xFFD9B23F);
  static const Color green = Color(0xFF6FBF73);
  static const Color blue = Color(0xFF5B8FD6);
  static const Color purple = Color(0xFF8C6FE0);
}
