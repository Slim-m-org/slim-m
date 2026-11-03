// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a stroke's or text's `color` paints as: one of the named keys, or any
/// `#rrggbb` string.
library;

import 'package:flutter/painting.dart';

const _maxCached = 512;
final _parsed = <String, Color?>{};

/// The colour a `#rrggbb` string names, or null for anything else.
///
/// Memoised, because painters resolve it for every stroke on every frame.
Color? parseCanvasHexColor(String text) {
  if (text.length != 7 || text.codeUnitAt(0) != 0x23) return null;
  if (_parsed.length >= _maxCached) _parsed.clear();
  return _parsed.putIfAbsent(text, () {
    final value = int.tryParse(text.substring(1), radix: 16);
    return value == null ? null : Color(0xFF000000 | value);
  });
}

/// A named key's colour in [named], else a hex colour, else [fallback].
Color resolveCanvasInk(
  Map<String, Color> named,
  String? key,
  Color fallback,
) {
  if (key == null) return fallback;
  return named[key] ?? parseCanvasHexColor(key) ?? fallback;
}

/// `#rrggbb` for [colour], lower case, as a stroke carries it on the wire.
String canvasHexOf(Color colour) {
  final rgb = colour.toARGB32() & 0xFFFFFF;
  return '#${rgb.toRadixString(16).padLeft(6, '0')}';
}
