// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How much text a note may carry, measured the way the server counts it.
library;

import 'dart:convert';

import 'package:flutter/services.dart';

/// The exact wire cost of a note's `props`: `text` JSON-escaped inside
/// `{"text":"..."}` and UTF-8 encoded, the same bytes the server's
/// `MAX_PROPS_BYTES` counts.
///
/// A *character* count was tried first and was wrong: `serde_json` (server
/// side) and `jsonEncode` (here) both leave any non-ASCII byte unescaped, so
/// a character costing more than one UTF-8 byte - ordinary CJK text, for
/// one, not a hostile string - costs that many wire bytes per unit of a
/// character count. 1800 CJK characters is 5,412 wire bytes, already over
/// the server's 4 KiB ceiling; only a control character's `\u00XX` escape is
/// worse, at 6 bytes each. Measuring the real encoded size is what a length
/// limit means here, not an approximation of it.
int noteWireBytes(String text) =>
    utf8.encode(jsonEncode({'text': text})).length;

/// A comfortable margin under the server's `MAX_PROPS_BYTES` (4 KiB), leaving
/// room for the request's own envelope fields alongside `props`.
const int maxNoteTextBytes = 4000;

/// Refuses an edit that would push [noteWireBytes] over [maxBytes], rather
/// than truncating mid-character: reverting to the last value that fit is
/// simple and can never split a surrogate pair or a grapheme cluster the way
/// slicing a string at a computed cut point could.
class NoteByteLimitFormatter extends TextInputFormatter {
  const NoteByteLimitFormatter({
    this.maxBytes = maxNoteTextBytes,
    this.onRefused,
  });

  final int maxBytes;

  /// Called when an edit is refused, so the field can say why nothing happened.
  final VoidCallback? onRefused;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (noteWireBytes(newValue.text) <= maxBytes) return newValue;
    onRefused?.call();
    return oldValue;
  }
}
