// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A note's text as block markdown: headings, quotes, lists, task boxes and fences, as one span tree.
///
/// A painter cannot lay out widgets, so structure is made of prefixes, sizes and weights over the
/// base style. The raw text is what a person edits; this is only how it reads on the board.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart' show NoteCheckMark;

import '../../messages/widgets/message_markdown_blocks.dart';
import 'canvas_note_spans.dart';

/// A heading's size next to the body text, from the design system's type scale.
double noteHeadingScale(int level) => switch (level) {
  1 => AppText.title.fontSize! / AppText.body.fontSize!,
  2 => AppText.heading.fontSize! / AppText.body.fontSize!,
  _ => 1,
};

const String _quoteBar = '| ';
const List<String> _bullets = ['•', '–', '◦'];
const String _checkGap = ' ';

/// [text] as blocks styled over [base].
InlineSpan buildNoteSpans(String text, TextStyle base, NoteSpanStyle style) {
  final blocks = splitMarkdownBlocks(text, notes: true);
  final children = <InlineSpan>[];
  for (final block in blocks) {
    if (children.isNotEmpty) children.add(const TextSpan(text: '\n'));
    children.addAll(_block(block, base, style));
  }
  return TextSpan(style: base, children: children);
}

List<InlineSpan> _block(
  MarkdownBlock block,
  TextStyle base,
  NoteSpanStyle style,
) => switch (block) {
  ParagraphBlock(:final text) => noteInlineSpans(text, style),
  HeadingBlock(:final level, :final text) => [
    TextSpan(
      style: TextStyle(
        fontSize: base.fontSize! * noteHeadingScale(level),
        fontWeight: AppWeights.semi,
      ),
      children: noteInlineSpans(text, style),
    ),
  ],
  QuoteBlock(:final text) => [
    for (final (i, line) in text.split('\n').indexed) ...[
      if (i > 0) const TextSpan(text: '\n'),
      TextSpan(
        text: _quoteBar,
        style: TextStyle(color: style.linkInk, fontWeight: AppWeights.semi),
      ),
      TextSpan(
        style: const TextStyle(fontStyle: FontStyle.italic),
        children: noteInlineSpans(line, style),
      ),
    ],
  ],
  ListBlock(:final items) => _list(items, base, style),
  FenceBlock(:final text) => [
    TextSpan(
      text: text.isEmpty ? ' ' : text,
      style: TextStyle(
        fontFamily: AppFonts.mono,
        backgroundColor: style.mentionFill,
      ),
    ),
  ],
};

List<InlineSpan> _list(
  List<ListItem> items,
  TextStyle base,
  NoteSpanStyle style,
) {
  final counts = List.filled(kMaxListDepth, 0);
  final spans = <InlineSpan>[];
  for (final (i, item) in items.indexed) {
    if (i > 0) spans.add(const TextSpan(text: '\n'));
    counts.fillRange(item.depth + 1, kMaxListDepth, 0);
    counts[item.depth]++;
    final indent = '  ' * item.depth;
    final checked = item.checked;
    if (checked != null) {
      spans
        ..add(TextSpan(text: indent))
        ..add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: NoteCheckMark(checked: checked, line: item.line),
          ),
        )
        ..add(const TextSpan(text: _checkGap));
    } else {
      final marker = item.ordered
          ? '${counts[item.depth]}.'
          : _bullets[item.depth];
      spans.add(TextSpan(text: '$indent$marker '));
    }
    spans.add(
      TextSpan(
        style: checked ?? false
            ? const TextStyle(decoration: TextDecoration.lineThrough)
            : null,
        children: noteInlineSpans(item.text, style),
      ),
    );
  }
  return spans;
}

/// [text] with the task box on source line [line] ticked or cleared, or null when that line holds none.
String? toggleNoteTask(String text, int line) {
  final lines = text.split('\n');
  if (line < 0 || line >= lines.length) return null;
  final box = RegExp(r'^(\s*[-*]\s+\[)([ xX])(\])').firstMatch(lines[line]);
  if (box == null) return null;
  final next = box.group(2) == ' ' ? 'x' : ' ';
  lines[line] = lines[line].replaceRange(
    box.start,
    box.end,
    '${box.group(1)}$next${box.group(3)}',
  );
  return lines.join('\n');
}
