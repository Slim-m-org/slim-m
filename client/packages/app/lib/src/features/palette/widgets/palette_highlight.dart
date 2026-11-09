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

/// The case-insensitive pattern for any word of [query], longest first so a
/// word that contains another is marked whole; null when [query] has no word.
RegExp? _wordsPattern(String query) {
  final words =
      query.split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toList()
        ..sort((a, b) => b.length.compareTo(a.length));
  if (words.isEmpty) return null;
  return RegExp(
    words.map(RegExp.escape).join('|'),
    caseSensitive: false,
    unicode: true,
  );
}

/// [text] with every occurrence of any word of [query] in bold, which is how
/// a full-text hit reads when its words need not sit together.
List<InlineSpan> paletteHighlightWordSpans(String text, String query) {
  final pattern = _wordsPattern(query);
  return pattern == null ? [TextSpan(text: text)] : _marks(text, pattern);
}

List<InlineSpan> _marks(String text, RegExp pattern) {
  final spans = <InlineSpan>[];
  var from = 0;
  for (final match in pattern.allMatches(text)) {
    if (match.start > from) {
      spans.add(TextSpan(text: text.substring(from, match.start)));
    }
    spans.add(
      TextSpan(
        text: match.group(0),
        style: const TextStyle(fontWeight: AppWeights.semi),
      ),
    );
    from = match.end;
  }
  if (from < text.length) spans.add(TextSpan(text: text.substring(from)));
  return spans.isEmpty ? [TextSpan(text: text)] : spans;
}

/// [text] on one line, started a little before its first match for [query]
/// when that match sits too far in to survive the row's line limit. It starts
/// at a word, so no emoji shortcode or markdown mark is cut in half.
String paletteSnippet(String text, String query) {
  const lead = 24;
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  final match = _wordsPattern(query)?.firstMatch(flat);
  if (match == null || match.start <= lead * 3) return flat;
  final from = flat.lastIndexOf(' ', match.start - lead) + 1;
  return '\u2026${flat.substring(from)}';
}

/// [spans] with every occurrence of any word of [query] in their text bold,
/// leaving what is not text (an emoji image, a chip) as it is.
List<InlineSpan> paletteHighlightInline(List<InlineSpan> spans, String query) {
  final pattern = _wordsPattern(query);
  if (pattern == null) return spans;
  return [for (final span in spans) _marked(span, pattern)];
}

InlineSpan _marked(InlineSpan span, RegExp pattern) {
  if (span is! TextSpan || span.semanticsLabel != null) return span;
  final text = span.text;
  final children = [
    for (final child in span.children ?? const <InlineSpan>[])
      _marked(child, pattern),
  ];
  if (text == null || !pattern.hasMatch(text)) {
    return TextSpan(
      text: text,
      style: span.style,
      recognizer: span.recognizer,
      children: children,
    );
  }
  return TextSpan(
    style: span.style,
    children: [
      for (final piece in _marks(text, pattern))
        TextSpan(
          text: (piece as TextSpan).text,
          style: piece.style,
          recognizer: span.recognizer,
        ),
      ...children,
    ],
  );
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
