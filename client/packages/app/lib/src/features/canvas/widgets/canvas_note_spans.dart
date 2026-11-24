// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A note's text as styled spans: the message parser's inline markdown,
/// mentions and links, drawn by a canvas painter rather than a widget tree.
///
/// Only spans are produced, since a painter cannot lay out a widget: blocks come from
/// `canvas_note_blocks.dart`, and a link is a `NoteLinkSpan` the board answers a tap on.
/// Space emoji images stay as the text typed; standard emoji are already glyphs.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart' show NoteLinkSpan;

import '../../messages/widgets/message_inline.dart';

/// What the note spans need beyond the text: who a mention can name and
/// the colours a mention and a link take.
class NoteSpanStyle {
  const NoteSpanStyle({
    required this.knownUsernames,
    required this.mentionInk,
    required this.mentionFill,
    required this.linkInk,
    this.mentionNames = const {},
  });

  final Set<String> knownUsernames;

  /// Lower-cased username to the name shown for it in this space.
  final Map<String, String> mentionNames;
  final Color mentionInk;
  final Color mentionFill;
  final Color linkInk;

  /// Changes whenever the spans for the same text would differ.
  int get revision => Object.hash(
    Object.hashAllUnordered(knownUsernames),
    Object.hashAllUnordered(
      mentionNames.entries.map((e) => Object.hash(e.key, e.value)),
    ),
    mentionInk,
    mentionFill,
    linkInk,
  );
}

const _reservedMentions = {'everyone', 'here'};

/// One line of [text] parsed with the message grammar, as spans over the style it is placed in.
List<InlineSpan> noteInlineSpans(String text, NoteSpanStyle style) =>
    _spans(parseInline(text), style);

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
  InlineChannelMention(:final channelId) => _link(
    '#channel',
    style,
    '$noteChannelLinkPrefix$channelId',
  ),
  InlineEmoji(:final raw) => TextSpan(text: raw),
  InlineLink(:final url) => _link(url, style, url),
  InlineMessageLink(:final raw) => _link('message link', style, raw),
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
  if (!known) return TextSpan(text: raw);
  final shown = style.mentionNames[name];
  return _chip(shown == null ? raw : '@$shown', style);
}

InlineSpan _chip(String text, NoteSpanStyle style) => TextSpan(
  text: text,
  style: TextStyle(
    color: style.mentionInk,
    backgroundColor: style.mentionFill,
    fontWeight: AppWeights.semi,
  ),
);

/// A link target that is a channel in this app, not an address.
const String noteChannelLinkPrefix = 'slimm-channel:';

InlineSpan _link(String text, NoteSpanStyle style, String url) => NoteLinkSpan(
  url: url,
  text: text,
  style: TextStyle(
    color: style.linkInk,
    decoration: TextDecoration.underline,
    decorationColor: style.linkInk,
  ),
);
