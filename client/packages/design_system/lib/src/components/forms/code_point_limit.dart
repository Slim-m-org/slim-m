// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Caps a field at a number of Unicode code points, the unit the server counts
/// in. Flutter's own length limit counts grapheme clusters, so a family emoji
/// that is one cluster but seven code points would pass here and fail there.
library;

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
    final caret = newValue.selection.baseOffset.clamp(0, text.length);
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: caret),
    );
  }
}

/// How long a field's value is for its limit: trimmed, in code points, the
/// way the server counts it, so a counter and a save check agree.
int inputCharCount(String text) => text.trim().runes.length;
