// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Indenting, outdenting and ending markdown list items in the composer, as
/// pure functions over a [TextEditingValue].
///
/// Depth is two spaces per level and stops at [kMaxListDepth], the same limit
/// the renderer in `message_markdown_blocks.dart` draws, so nothing the
/// composer can produce is flattened when the message is shown.
library;

import 'package:flutter/material.dart';

import 'message_markdown_blocks.dart' show kMaxListDepth;

final RegExp _listLine = RegExp(r'^( {0,5})(?:([-*])|(\d+)\.)([ \t]+)(.*)$');

/// One line parsed as a list item.
class ListLine {
  ListLine._(this.indent, this.bullet, this.number, this.gap, this.content);

  final String indent;
  final String? bullet;
  final int? number;
  final String gap;
  final String content;

  bool get ordered => number != null;
  int get depth => (indent.length ~/ 2).clamp(0, kMaxListDepth - 1);
  int get prefixLength => toString().length - content.length;
  bool get isEmpty => content.trim().isEmpty;

  static ListLine? parse(String line) {
    final m = _listLine.firstMatch(line);
    if (m == null) return null;
    final number = m.group(3);
    return ListLine._(
      m.group(1)!,
      m.group(2),
      number == null ? null : int.parse(number),
      m.group(4)!,
      m.group(5)!,
    );
  }

  ListLine _with({required int depth, int? number}) => ListLine._(
    '  ' * depth,
    bullet,
    ordered ? number ?? this.number : null,
    gap,
    content,
  );

  @override
  String toString() => '$indent${ordered ? '$number.' : bullet}$gap$content';
}

/// The number an ordered item at [depth] takes after the lines above [index]:
/// one past the nearest sibling above it, or 1 when it opens a sub-list.
int _numberAt(List<String> lines, int index, int depth) {
  for (var i = index - 1; i >= 0; i--) {
    final above = ListLine.parse(lines[i]);
    if (above == null || above.depth < depth) return 1;
    if (above.depth == depth) return above.ordered ? above.number! + 1 : 1;
  }
  return 1;
}

({int first, int last, List<String> lines, List<int> starts}) _selectedLines(
  TextEditingValue value,
) {
  final lines = value.text.split('\n');
  final starts = <int>[];
  var offset = 0;
  for (final line in lines) {
    starts.add(offset);
    offset += line.length + 1;
  }
  int lineAt(int position) {
    var i = 0;
    while (i + 1 < starts.length && starts[i + 1] <= position) {
      i++;
    }
    return i;
  }

  final selection = value.selection;
  final start = selection.start < 0 ? value.text.length : selection.start;
  final end = selection.end < 0 ? value.text.length : selection.end;
  final first = lineAt(start);
  var last = lineAt(end);
  if (end > start && last > first && end == starts[last]) last--;
  return (first: first, last: last, lines: lines, starts: starts);
}

/// Moves every list line in the selection by [delta] levels. Null when the
/// selection touches no list line at all, so the key can fall through. A list
/// line that cannot move (already at the edge) still counts: the key is
/// consumed and the text is returned as it was.
TextEditingValue? _shiftLines(TextEditingValue value, int delta) {
  final sel = _selectedLines(value);
  final lines = List.of(sel.lines);
  final prefixChange = <int, ({int before, int after})>{};
  for (var i = sel.first; i <= sel.last; i++) {
    final item = ListLine.parse(lines[i]);
    if (item == null) continue;
    final depth = (item.depth + delta).clamp(0, kMaxListDepth - 1);
    prefixChange[i] = (before: item.prefixLength, after: item.prefixLength);
    if (depth == item.depth) continue;
    lines[i] = item
        ._with(depth: depth, number: _numberAt(lines, i, depth))
        .toString();
    prefixChange[i] = (
      before: item.prefixLength,
      after: ListLine.parse(lines[i])!.prefixLength,
    );
  }
  if (prefixChange.isEmpty) return null;

  int moved(int offset) {
    var shift = 0;
    for (var i = 0; i < sel.starts.length; i++) {
      final change = prefixChange[i];
      if (change == null) continue;
      final start = sel.starts[i];
      if (offset < start) break;
      final grown = change.after - change.before;
      final into = offset - start;
      shift += into >= change.before ? grown : (into + grown).clamp(0, grown);
    }
    return offset + shift;
  }

  final selection = value.selection;
  return TextEditingValue(
    text: lines.join('\n'),
    selection: selection.isValid
        ? TextSelection(
            baseOffset: moved(selection.baseOffset),
            extentOffset: moved(selection.extentOffset),
          )
        : selection,
  );
}

/// Tab: one level deeper for each list line in the selection.
TextEditingValue? indentList(TextEditingValue value) => _shiftLines(value, 1);

/// Shift+Tab: one level shallower. An empty top-level item has nowhere left to
/// go, so it ends the list instead.
TextEditingValue? outdentList(TextEditingValue value) =>
    leaveEmptyItem(value) ?? _shiftLines(value, -1);

/// The offset where the line holding [caret] starts. `lastIndexOf` rejects a
/// negative start, so a caret at the very start of the text is its own line start.
int lineStartAt(String text, int caret) =>
    caret == 0 ? 0 : text.lastIndexOf('\n', caret - 1) + 1;

/// What Enter, Backspace or Shift+Tab does at the end of an item with nothing
/// typed in it: a nested item steps out one level, a top-level one loses its
/// marker and so ends the list. Null when the caret is not at such an item.
TextEditingValue? leaveEmptyItem(TextEditingValue value) {
  if (!value.selection.isCollapsed || value.selection.baseOffset < 0) {
    return null;
  }
  final caret = value.selection.baseOffset;
  final text = value.text;
  final lineStart = lineStartAt(text, caret);
  final lineEnd = text.indexOf('\n', caret);
  if (lineEnd != -1 && lineEnd != caret) return null;
  final item = ListLine.parse(text.substring(lineStart, caret));
  if (item == null || !item.isEmpty) return null;
  if (item.depth > 0) return _shiftLines(value, -1);
  return TextEditingValue(
    text: text.replaceRange(lineStart, caret, ''),
    selection: TextSelection.collapsed(offset: lineStart),
  );
}
