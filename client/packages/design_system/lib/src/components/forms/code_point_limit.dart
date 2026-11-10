// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Caps a field at a number of Unicode code points, the unit the server counts
/// in. Flutter's own length limit counts grapheme clusters, so a family emoji
/// that is one cluster but seven code points would pass here and fail there.
library;

import 'dart:math' as math;

import 'package:flutter/services.dart';

class CodePointLengthLimit extends TextInputFormatter {
  CodePointLengthLimit(this.max) : assert(max > 0);

  final int max;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final runes = newValue.text.runes;
    if (runes.length <= max) return newValue;
    // A paste is cut to fit rather than refused whole, so the start of it still lands.
    final text = String.fromCharCodes(runes.take(max));
    return TextEditingValue(
      text: text,
      selection: _clampSelection(newValue.selection, text.length),
      composing: _clampComposing(newValue.composing, text.length),
    );
  }
}

TextSelection _clampSelection(TextSelection selection, int length) =>
    selection.copyWith(
      baseOffset: math.min(selection.baseOffset, length),
      extentOffset: math.min(selection.extentOffset, length),
    );

/// Keeps an IME composition that survives the cut, as Flutter's own limit does.
TextRange _clampComposing(TextRange composing, int length) {
  if (composing.isCollapsed || composing.start >= length) {
    return TextRange.empty;
  }
  return TextRange(
    start: composing.start,
    end: math.min(composing.end, length),
  );
}

/// How long a field's value is for its limit: trimmed, in code points, the
/// way the server counts it, so a counter and a save check agree.
int inputCharCount(String text) => text.trim().runes.length;
