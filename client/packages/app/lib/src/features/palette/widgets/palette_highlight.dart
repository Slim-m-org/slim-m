// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Query highlighting shared by the palette rows and the member picker.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// [text] with the first case-insensitive occurrence of [query] in bold.
///
/// Matches in [text] itself: a lower-cased copy can be longer than the
/// original (dart2js maps U+0130 to two code units), which skews its offsets.
List<InlineSpan> paletteHighlightSpans(String text, String query) {
  final match = query.isEmpty
      ? null
      : RegExp(
          RegExp.escape(query),
          caseSensitive: false,
          unicode: true,
        ).firstMatch(text);
  if (match == null) return [TextSpan(text: text)];
  return [
    if (match.start > 0) TextSpan(text: text.substring(0, match.start)),
    TextSpan(
      text: match.group(0),
      style: const TextStyle(fontWeight: AppWeights.semi),
    ),
    if (match.end < text.length) TextSpan(text: text.substring(match.end)),
  ];
}

Widget paletteHighlighted(
  String text,
  String query,
  TextStyle style, {
  int maxLines = 1,
}) => Text.rich(
  TextSpan(children: paletteHighlightSpans(text, query)),
  style: style,
  maxLines: maxLines,
  overflow: TextOverflow.ellipsis,
);
