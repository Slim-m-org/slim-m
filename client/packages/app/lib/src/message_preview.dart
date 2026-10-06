// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One-line previews of a message's text, for quotes and banners.
library;

import 'widgets/message_inline.dart';

final _fence = RegExp(r'```[\s\S]*?(?:```|$)');
final _whitespace = RegExp(r'\s+');

/// What a spoiler reads as in a preview: the transcript hides it, so a quote
/// or a banner must not show what is under it.
const spoilerPlaceholder = '[spoiler]';

/// [content] flattened to one line of plain text: a fenced block becomes
/// "[code]", inline code loses its backticks, a spoiler becomes
/// [spoilerPlaceholder] and bold, italic and strikethrough lose their markers.
/// Walks the same parse the transcript renders, so a preview can never show
/// what the transcript hides. Empty when nothing is left.
String plainPreview(String content) {
  final withoutFences = content.replaceAll(_fence, ' [code] ');
  final text = parseInline(withoutFences).map(_flatten).join();
  return text.replaceAll(_whitespace, ' ').trim();
}

String _flatten(InlineNode node) => switch (node) {
  InlineText(:final text) => text,
  InlineCode(:final text) => text,
  InlineMention(:final raw) => raw,
  InlineRoleMention(:final name) => '@$name',
  InlineEmoji(:final raw) => raw,
  InlineLink(:final url) => url,
  InlineMessageLink(:final raw) => raw,
  InlineBold(:final children) ||
  InlineItalic(:final children) ||
  InlineStrikethrough(:final children) => children.map(_flatten).join(),
  InlineSpoiler() => spoilerPlaceholder,
};

/// [plainPreview] cut to [maxRunes] runes, or "(no text)" when it is empty.
/// Rune-safe: `String.substring` cuts mid-surrogate outside the BMP.
String previewSnippet(String content, {required int maxRunes}) {
  final oneLine = plainPreview(content);
  if (oneLine.isEmpty) return '(no text)';
  final runes = oneLine.runes.toList(growable: false);
  if (runes.length <= maxRunes) return oneLine;
  return '${String.fromCharCodes(runes.take(maxRunes))}…';
}
