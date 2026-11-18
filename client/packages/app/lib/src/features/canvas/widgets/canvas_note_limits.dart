// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How much text a note may carry, measured the way the server counts it.
library;

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show StringCharacters;

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

/// Said once a note is full; the cap is bytes, so emoji and non-Latin text fill it sooner.
const noteFullSentence =
    'This note is full. A note holds about 4,000 characters, fewer with '
    'emoji or non-Latin text.';

/// Keeps an edit that would push [noteWireBytes] over [maxBytes] to as much
/// of what it added as fits, cut between grapheme clusters so a surrogate
/// pair or an emoji sequence is never split, and reports the cut.
class NoteByteLimitFormatter extends TextInputFormatter {
  const NoteByteLimitFormatter({
    this.maxBytes = maxNoteTextBytes,
    this.onRefused,
  });

  final int maxBytes;

  /// Called when an edit is cut or refused, so the field can say why.
  final VoidCallback? onRefused;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (noteWireBytes(newValue.text) <= maxBytes) return newValue;
    onRefused?.call();
    final kept = _keepWhatFits(oldValue.text, newValue.text);
    return kept ?? oldValue;
  }

  /// The new text with its insertion cut to fit, or null when nothing of it does.
  TextEditingValue? _keepWhatFits(String before, String after) {
    final head = _sharedPrefix(before, after);
    final tail = _sharedSuffix(before, after, head);
    final prefix = after.substring(0, head);
    final suffix = after.substring(after.length - tail);
    final added = after.substring(head, after.length - tail).characters;
    String join(int take) => '$prefix${added.take(take)}$suffix';
    var low = 0;
    var high = added.length;
    while (low < high) {
      final mid = (low + high + 1) ~/ 2;
      if (noteWireBytes(join(mid)) <= maxBytes) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    if (low == 0) return null;
    final text = join(low);
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length - suffix.length),
    );
  }
}

int _sharedPrefix(String a, String b) {
  var i = 0;
  while (i < a.length && i < b.length && a.codeUnitAt(i) == b.codeUnitAt(i)) {
    i++;
  }
  return _toBoundary(b, i);
}

/// Never overlaps the prefix, so a repeated character is counted once.
int _sharedSuffix(String a, String b, int prefix) {
  var i = 0;
  while (i < a.length - prefix &&
      i < b.length - prefix &&
      a.codeUnitAt(a.length - 1 - i) == b.codeUnitAt(b.length - 1 - i)) {
    i++;
  }
  return b.length - _toBoundary(b, b.length - i, up: true);
}

/// Moves [index] off the middle of a surrogate pair.
int _toBoundary(String text, int index, {bool up = false}) {
  if (index <= 0 || index >= text.length) return index;
  final unit = text.codeUnitAt(index);
  final lowSurrogate = unit >= 0xDC00 && unit <= 0xDFFF;
  if (!lowSurrogate) return index;
  return up ? index + 1 : index - 1;
}
