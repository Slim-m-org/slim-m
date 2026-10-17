// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Splitting an already-fence-free text run into structural markdown blocks:
/// headings, block quotes and lists. Each is recognised a whole line at a
/// time, since none of them can start except at the beginning of a line, and
/// this file has no opinion about inline formatting inside one: that is
/// layered on separately by whoever renders a block's text, so a heading or a
/// list item can still carry `**bold**` without this file knowing about it.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

sealed class MarkdownBlock {
  const MarkdownBlock();
}

class ParagraphBlock extends MarkdownBlock {
  const ParagraphBlock(this.text);
  final String text;
}

/// [level] is 1, 2 or 3 for `#`, `##`, `###`.
class HeadingBlock extends MarkdownBlock {
  const HeadingBlock(this.level, this.text);
  final int level;
  final String text;
}

class QuoteBlock extends MarkdownBlock {
  const QuoteBlock(this.text);
  final String text;
}

/// How many list levels render: depth 0, 1 and 2. The composer's Tab stops at
/// the same depth, so what it lets you type is what a message shows.
const int kMaxListDepth = 3;

/// One list item. [depth] runs 0 to [kMaxListDepth] - 1, two spaces of indent
/// per level. [ordered] is the item's own marker kind, since a bullet can nest
/// under a number (and the reverse) without ending the list it sits in.
class ListItem {
  const ListItem(this.depth, this.text, {this.ordered = false});
  final int depth;
  final String text;
  final bool ordered;
}

class ListBlock extends MarkdownBlock {
  const ListBlock(this.ordered, this.items);
  final bool ordered;
  final List<ListItem> items;
}

final RegExp _heading = RegExp(r'^(#{1,3})[ \t]+(.*)$');

/// `(?:>[ \t]?)+` rather than one `>`: quotes nest, and stripping only the
/// outermost marker left every deeper one sitting in the rendered text as a
/// literal `>` character. Consuming every leading marker in one match
/// flattens the whole chain into a single quote box instead. This began as a
/// forwarding bug, back when a forward was a client-composed quote block
/// that a second forward would requote; forwards are modelled now
/// (`forwarded_message_card.dart`) and no longer produce these, but ordinary
/// hand-typed nested quotes still do.
final RegExp _quote = RegExp(r'^(?:>[ \t]?)+(.*)$');
final RegExp _bullet = RegExp(r'^( {0,5})[-*][ \t]+(.*)$');
final RegExp _ordered = RegExp(r'^( {0,5})\d+\.[ \t]+(.*)$');

int _depthOf(String indent) => (indent.length ~/ 2).clamp(0, kMaxListDepth - 1);

/// Splits [text] into the block elements above.
///
/// A run of lines with none of the leading markers becomes one
/// [ParagraphBlock], any blank lines inside it preserved exactly as before
/// this file existed: a plain message with no markdown at all still becomes
/// exactly one block holding the whole text, unchanged.
List<MarkdownBlock> splitMarkdownBlocks(String text) {
  final blocks = <MarkdownBlock>[];
  final paragraph = <String>[];
  final quote = <String>[];
  var listOrdered = false;
  final listItems = <ListItem>[];

  void flushParagraph() {
    if (paragraph.isNotEmpty) {
      final text = paragraph.join('\n');
      // A blank line between two other blocks lands here as an empty paragraph; drop it, not a real block.
      if (text.trim().isNotEmpty) blocks.add(ParagraphBlock(text));
      paragraph.clear();
    }
  }

  void flushQuote() {
    if (quote.isNotEmpty) {
      blocks.add(QuoteBlock(quote.join('\n')));
      quote.clear();
    }
  }

  void flushList() {
    if (listItems.isNotEmpty) {
      blocks.add(ListBlock(listOrdered, List.of(listItems)));
      listItems.clear();
    }
  }

  for (final line in text.split('\n')) {
    final heading = _heading.firstMatch(line);
    if (heading != null) {
      flushParagraph();
      flushQuote();
      flushList();
      blocks.add(HeadingBlock(heading.group(1)!.length, heading.group(2)!));
      continue;
    }

    final quoteMatch = _quote.firstMatch(line);
    if (quoteMatch != null) {
      flushParagraph();
      flushList();
      quote.add(quoteMatch.group(1)!);
      continue;
    }
    flushQuote();

    final bullet = _bullet.firstMatch(line);
    final ordered = _ordered.firstMatch(line);
    final item = ordered ?? bullet;
    if (item != null) {
      flushParagraph();
      final isOrdered = ordered != null;
      final depth = _depthOf(item.group(1)!);
      // Only a change of marker at the top level starts a new list; a nested one belongs to its parent.
      if (listItems.isNotEmpty && depth == 0 && listOrdered != isOrdered) {
        flushList();
      }
      if (listItems.isEmpty) listOrdered = isOrdered;
      listItems.add(ListItem(depth, item.group(2)!, ordered: isOrdered));
      continue;
    }
    flushList();

    paragraph.add(line);
  }
  flushParagraph();
  flushQuote();
  flushList();
  return blocks;
}

/// A block quote: a left rule beside the quoted content, matching Discord's
/// own cue rather than inventing a new one.
class MarkdownQuote extends StatelessWidget {
  const MarkdownQuote({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Container(
      padding: const EdgeInsets.only(left: AppSpacing.s12),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: tokens.borderSubtle, width: 3)),
      ),
      child: child,
    );
  }
}

/// One rendered list, nested up to [kMaxListDepth] levels. [children] is
/// already-built inline text per item, matching [items] one for one; this
/// widget only lays markers and indentation around what it is handed.
class MarkdownList extends StatelessWidget {
  const MarkdownList({super.key, required this.items, required this.children});

  final List<ListItem> items;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final markers = _markersFor(items);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < items.length; i++)
          Padding(
            padding: EdgeInsets.only(
              left: items[i].depth * AppSpacing.s16,
              bottom: i == items.length - 1 ? 0 : AppSpacing.s4,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: AppSpacing.s20,
                  child: Text(
                    markers[i],
                    style: AppText.body.copyWith(color: tokens.textSecondary),
                  ),
                ),
                Expanded(child: children[i]),
              ],
            ),
          ),
      ],
    );
  }
}

/// One marker per item: a bullet glyph per depth, or a number that restarts
/// whenever a shallower item intervenes, the way a nested sub-list counts.
List<String> _markersFor(List<ListItem> items) {
  const bullets = ['•', '–', '◦'];
  final counts = List.filled(kMaxListDepth, 0);
  return [
    for (final item in items)
      () {
        counts.fillRange(item.depth + 1, kMaxListDepth, 0);
        counts[item.depth]++;
        return item.ordered ? '${counts[item.depth]}.' : bullets[item.depth];
      }(),
  ];
}
