// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A note's text as styled spans: the message parser's inline markdown,
/// mentions and links, drawn by a canvas painter rather than a widget tree.
///
/// Only `TextSpan`s are produced, since a painter cannot lay out a widget.
/// Block markdown (headings, quotes, fences) and Space emoji images stay as
/// the text typed; standard emoji are already glyphs.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../messages/widgets/message_inline.dart';

/// What [buildNoteSpans] needs beyond the text: who a mention can name and
/// the colours a mention and a link take.
class NoteSpanStyle {
  const NoteSpanStyle({
    required this.knownUsernames,
    required this.mentionInk,
    required this.mentionFill,
    required this.linkInk,
  });

  final Set<String> knownUsernames;
  final Color mentionInk;
  final Color mentionFill;
  final Color linkInk;

  /// Changes whenever the spans for the same text would differ.
  int get revision =>
      Object.hash(knownUsernames.length, mentionInk, mentionFill, linkInk);
}

const _reservedMentions = {'everyone', 'here'};

/// [text] parsed with the message grammar and styled over [base].
InlineSpan buildNoteSpans(String text, TextStyle base, NoteSpanStyle style) =>
    TextSpan(style: base, children: _spans(parseInline(text), style));

List<InlineSpan> _spans(List<InlineNode> nodes, NoteSpanStyle style) => [
  for (final node in nodes) _span(node, style),
];

InlineSpan _span(InlineNode node, NoteSpanStyle style) => switch (node) {
  InlineText(:final text) => TextSpan(text: text),
  InlineCode(:final text) => TextSpan(
    text: text,
    style: const TextStyle(fontFamily: AppFonts.mono),
  ),
  InlineMention(:final raw) => _mention(raw, style),
  InlineRoleMention(:final name) => _chip('@$name', style),
  InlineChannelMention() => const TextSpan(text: '#channel'),
  InlineEmoji(:final raw) => TextSpan(text: raw),
  InlineLink(:final url) => _link(url, style),
  InlineMessageLink() => _link('message link', style),
  InlineBold(:final children) => TextSpan(
    style: const TextStyle(fontWeight: AppWeights.semi),
    children: _spans(children, style),
  ),
  InlineItalic(:final children) => TextSpan(
    style: const TextStyle(fontStyle: FontStyle.italic),
    children: _spans(children, style),
  ),
  InlineStrikethrough(:final children) => TextSpan(
    style: const TextStyle(decoration: TextDecoration.lineThrough),
    children: _spans(children, style),
  ),
  InlineSpoiler(:final children) => TextSpan(children: _spans(children, style)),
};

InlineSpan _mention(String raw, NoteSpanStyle style) {
  final name = raw.substring(1).toLowerCase();
  final known =
      style.knownUsernames.contains(name) || _reservedMentions.contains(name);
  return known ? _chip(raw, style) : TextSpan(text: raw);
}

InlineSpan _chip(String text, NoteSpanStyle style) => TextSpan(
  text: text,
  style: TextStyle(
    color: style.mentionInk,
    backgroundColor: style.mentionFill,
    fontWeight: AppWeights.semi,
  ),
);

InlineSpan _link(String text, NoteSpanStyle style) => TextSpan(
  text: text,
  style: TextStyle(
    color: style.linkInk,
    decoration: TextDecoration.underline,
    decorationColor: style.linkInk,
  ),
);
