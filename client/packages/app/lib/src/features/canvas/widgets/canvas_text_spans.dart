// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A text box's text as spans: plain, except that a known custom `:name:` is an emoji placeholder in place.
library;

import 'package:flutter/material.dart';

import '../../composer/widgets/composer_shortcode_convert.dart';
import 'canvas_note_spans.dart';

/// [text] over [base] with each custom emoji [style] knows drawn in place of its shortcode.
InlineSpan buildTextBoxSpans(String text, TextStyle base, NoteSpanStyle style) {
  final ranges = customEmojiRangesIn(text, style.customEmoji);
  if (ranges.isEmpty) return TextSpan(text: text, style: base);
  var at = 0;
  final children = <InlineSpan>[];
  for (final range in ranges) {
    if (range.start > at) {
      children.add(TextSpan(text: text.substring(at, range.start)));
    }
    children.add(emojiSpan(':${range.name}:', style));
    at = range.end;
  }
  if (at < text.length) children.add(TextSpan(text: text.substring(at)));
  return TextSpan(style: base, children: children);
}
