// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A long search hit cut to the lines around what matched.
library;

/// The most lines of a message a search hit shows.
const kSearchHitLines = 6;

/// [content] cut to [kSearchHitLines] lines, starting a line above the first
/// one holding a word of [query], with an ellipsis line where it was cut.
///
/// A message with a code fence is left whole: a cut could open or close the
/// fence on the wrong side. The hit's height clamp still bounds it.
String searchHitExcerpt(String content, String query) {
  final lines = content.split('\n');
  if (lines.length <= kSearchHitLines || content.contains('```')) {
    return content;
  }
  final words = [
    for (final word in query.toLowerCase().split(RegExp(r'\s+')))
      if (word.isNotEmpty && !word.contains(':')) word,
  ];
  final hit = lines.indexWhere(
    (line) => words.any(line.toLowerCase().contains),
  );
  final start = (hit - 1).clamp(0, lines.length - kSearchHitLines);
  final end = start + kSearchHitLines;
  return [
    if (start > 0) '…',
    ...lines.sublist(start, end),
    if (end < lines.length) '…',
  ].join('\n');
}
