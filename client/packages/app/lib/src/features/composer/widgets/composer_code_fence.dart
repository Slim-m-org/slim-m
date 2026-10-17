// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Fenced code blocks in the composer, as pure functions over a
/// [TextEditingValue]: inserting one, telling whether the caret is inside
/// one, and the newline Enter types there instead of sending.
library;

import 'package:flutter/widgets.dart';

const String kCodeFence = '```';

/// 0 for an ordinary line, 1 for a fence that opens or closes, 2 for a whole
/// block on one line (```x```), which leaves the fence state as it was.
int _fenceWeight(String line) {
  final trimmed = line.trimLeft();
  if (!trimmed.startsWith(kCodeFence)) return 0;
  return trimmed.indexOf(kCodeFence, kCodeFence.length) > 0 ? 2 : 1;
}

/// Whether the caret sits after a fence that has not been closed yet.
bool caretInOpenFence(TextEditingValue value) {
  final caret = value.selection.baseOffset;
  if (caret < 0 || caret > value.text.length) return false;
  final lines = value.text.substring(0, caret).split('\n');
  return lines.fold<int>(0, (n, line) => n + _fenceWeight(line)).isOdd;
}

/// Enter inside a block: a newline that keeps the current line's indent.
TextEditingValue newlineInFence(TextEditingValue value) {
  final sel = value.selection;
  final text = value.text;
  final lineStart = text.lastIndexOf('\n', sel.start - 1) + 1;
  final indent = RegExp(
    r'^[ \t]*',
  ).stringMatch(text.substring(lineStart, sel.start))!;
  final inserted = '\n$indent';
  return TextEditingValue(
    text: text.replaceRange(sel.start, sel.end, inserted),
    selection: TextSelection.collapsed(offset: sel.start + inserted.length),
  );
}

/// A fenced block tagged [language] at the selection. Empty, the caret lands
/// on the block's blank middle line; with text selected, the selection
/// becomes the block's body and the caret lands after the closing fence.
/// The fences always sit on lines of their own.
TextEditingValue insertCodeFence(
  TextEditingValue value, {
  String language = '',
}) {
  final text = value.text;
  final sel = value.selection.isValid
      ? value.selection
      : TextSelection.collapsed(offset: text.length);
  final selected = text.substring(sel.start, sel.end);
  final lead = sel.start == 0 || text[sel.start - 1] == '\n' ? '' : '\n';
  final trail = sel.end == text.length || text[sel.end] == '\n' ? '' : '\n';
  final open = '$lead$kCodeFence$language\n';
  final body = selected.isEmpty || selected.endsWith('\n')
      ? selected
      : '$selected\n';
  final block = selected.isEmpty
      ? '$open\n$kCodeFence$trail'
      : '$open$body$kCodeFence$trail';
  final caret = selected.isEmpty
      ? sel.start + open.length
      : sel.start + block.length - trail.length;
  return TextEditingValue(
    text: text.replaceRange(sel.start, sel.end, block),
    selection: TextSelection.collapsed(offset: caret),
  );
}
