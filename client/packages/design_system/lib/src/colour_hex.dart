// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `#RRGGBB` text to and from a [Color], shared by the colour picker and the
/// profile colour the server stores.
library;

import 'package:flutter/painting.dart';

/// 0xRRGGBB for [colour].
int rgbOfColour(Color colour) => colour.toARGB32() & 0xFFFFFF;

/// `#RRGGBB` for [colour], upper case.
String hexOfColour(Color colour) =>
    '#${rgbOfColour(colour).toRadixString(16).padLeft(6, '0').toUpperCase()}';

/// The opaque colour a `#RRGGBB` or `RRGGBB` string names, or null when it names none.
Color? colourFromHexText(String text) {
  final digits = text.trim().replaceFirst('#', '');
  if (!RegExp(r'^[0-9a-fA-F]{6}$').hasMatch(digits)) return null;
  return Color(0xFF000000 | int.parse(digits, radix: 16));
}
