// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Query highlighting shared by the palette rows and the member picker.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// [text] with the first case-insensitive occurrence of [query] in bold.
List<InlineSpan> paletteHighlightSpans(String text, String query) {
  final at = query.isEmpty
      ? -1
      : text.toLowerCase().indexOf(query.toLowerCase());
  if (at < 0) return [TextSpan(text: text)];
  final end = at + query.length;
  return [
    if (at > 0) TextSpan(text: text.substring(0, at)),
    TextSpan(
      text: text.substring(at, end),
      style: const TextStyle(fontWeight: AppWeights.semi),
    ),
    if (end < text.length) TextSpan(text: text.substring(end)),
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
