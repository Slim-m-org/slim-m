// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Inserting text at a field's caret, shared by every field that takes a
/// picked emoji or a snippet.
library;

import 'package:flutter/widgets.dart';

/// Replaces the selection (or appends when the field never had one) with
/// [text], leaving the caret [caretOffset] characters in, default after it.
void insertAtSelection(
  TextEditingController controller,
  String text, {
  int? caretOffset,
}) {
  final selection = controller.selection;
  final value = controller.text;
  final start = selection.start < 0 ? value.length : selection.start;
  final end = selection.end < 0 ? value.length : selection.end;
  controller.value = TextEditingValue(
    text: value.replaceRange(start, end, text),
    selection: TextSelection.collapsed(
      offset: start + (caretOffset ?? text.length),
    ),
  );
}
