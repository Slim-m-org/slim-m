// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What typing a completed `:name:` does to the composer's text.
///
/// Pure string logic with no widget in it, for the same reason
/// `composer_autocomplete_query.dart` is: every interesting case is a string
/// case. A standard emoji's shortcode becomes its glyph the moment the
/// closing colon lands, which is what the autocomplete list inserts too. A
/// Space emoji keeps its text, since a plain text field cannot draw an image
/// in place; the composer previews it instead.
library;

import '../../../widgets/message_fences.dart';
import '../../../widgets/message_inline.dart';
import '../../../widgets/standard_emoji.dart';

final RegExp _nameChar = RegExp(r'[A-Za-z0-9_]');
final RegExp _fenceMarker = RegExp(r'^```[A-Za-z0-9_+#-]*\s*$');

/// A shortcode that has just been replaced by its glyph, kept so the next
/// edit can undo it.
class ShortcodeConversion {
  const ShortcodeConversion({
    required this.start,
    required this.original,
    required this.glyph,
    required this.textAfter,
  });

  /// Offset of the glyph, and so of the opening colon it replaced.
  final int start;
  final String original;
  final String glyph;

  /// The whole text right after converting, to tell an untouched field from an edited one.
  final String textAfter;

  int get end => start + glyph.length;
}

/// The conversion a single typed `:` at [caret] completes, or null.
///
/// [previous] is the text before the keystroke: only a lone `:` inserted at
/// the caret converts, so a paste, a deletion or an undo that leaves a whole
/// `:bug:` behind is never converted behind the writer's back.
/// [spaceNames] are lowercase custom names, which win over a standard
/// shortcode of the same name, as they do when a message renders.
ShortcodeConversion? convertCompletedShortcode({
  required String previous,
  required String text,
  required int caret,
  required Set<String> spaceNames,
}) {
  if (caret < 3 || caret > text.length || text[caret - 1] != ':') return null;
  if (text.length != previous.length + 1) return null;
  if (text.replaceRange(caret - 1, caret, '') != previous) return null;

  var open = caret - 2;
  while (open >= 0 && _nameChar.hasMatch(text[open])) {
    open--;
  }
  if (open < 0 || text[open] != ':' || open == caret - 2) return null;
  if (open > 0 && !_isSpace(text[open - 1])) return null;

  final name = text.substring(open + 1, caret - 1).toLowerCase();
  if (spaceNames.contains(name) || _insideCode(text, open)) return null;
  final glyph = standardEmojiFor(':$name:');
  if (glyph == null) return null;

  return ShortcodeConversion(
    start: open,
    original: text.substring(open, caret),
    glyph: glyph,
    textAfter: text.replaceRange(open, caret, glyph),
  );
}

/// The undone text and caret when [text] is [conversion]'s glyph removed by
/// a backspace, or null when the edit was anything else.
({String text, int caret})? undoConversion({
  required ShortcodeConversion conversion,
  required String text,
  required int caret,
}) {
  final withoutGlyph = conversion.textAfter.replaceRange(
    conversion.start,
    conversion.end,
    '',
  );
  if (text != withoutGlyph || caret != conversion.start) return null;
  return (
    text: text.replaceRange(
      conversion.start,
      conversion.start,
      conversion.original,
    ),
    caret: conversion.start + conversion.original.length,
  );
}

/// The names of the Space emoji a draft would render as images, in order,
/// without repeats. Reads the draft the way a message is read, so a
/// shortcode in a code span or fence is left out.
List<String> spaceShortcodesIn(String text, Set<String> spaceNames) {
  final found = <String>[];
  void visit(List<InlineNode> nodes) {
    for (final node in nodes) {
      switch (node) {
        case InlineEmoji(:final raw):
          final name = raw.substring(1, raw.length - 1).toLowerCase();
          if (spaceNames.contains(name) && !found.contains(name)) {
            found.add(name);
          }
        case InlineBold(:final children) ||
            InlineItalic(:final children) ||
            InlineStrikethrough(:final children) ||
            InlineSpoiler(:final children):
          visit(children);
        default:
      }
    }
  }

  for (final block in splitMessageBlocks(text)) {
    if (block case TextBlock(:final text)) visit(parseInline(text));
  }
  return found;
}

bool _isSpace(String ch) => ch == ' ' || ch == '\n' || ch == '\t';

/// Whether [offset] sits inside an inline code span on its line or a fence
/// still open above it. An open fence counts as code even before its close
/// is typed, which `splitMessageBlocks` does not: converting inside a block
/// the writer is midway through would be the surprise.
bool _insideCode(String text, int offset) {
  final upTo = text.substring(0, offset).split('\n');
  final inFence = upTo
      .sublist(0, upTo.length - 1)
      .where(_fenceMarker.hasMatch)
      .length
      .isOdd;
  if (inFence) return true;
  return '`'.allMatches(upTo.last).length.isOdd;
}
