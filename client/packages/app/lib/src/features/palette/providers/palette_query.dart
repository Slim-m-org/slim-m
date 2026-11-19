// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The palette's field as filters are typed into it: the word being typed,
/// and finished filter words lifted out into chips.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../messages/providers/message_search_query.dart';

/// The word the caret is at the end of, and where it starts; empty after a space.
({int start, String word}) wordBeforeCaret(TextEditingValue value) {
  final caret = _caret(value);
  for (final span in searchWordSpans(value.text)) {
    if (span.start < caret && caret <= span.end) {
      return (start: span.start, word: value.text.substring(span.start, caret));
    }
  }
  return (start: caret, word: '');
}

/// [value] with the word before the caret replaced by [replacement], caret after it.
TextEditingValue replaceWordBeforeCaret(
  TextEditingValue value,
  String replacement,
) {
  final caret = _caret(value);
  final (:start, :word) = wordBeforeCaret(value);
  final text =
      value.text.substring(0, start) +
      replacement +
      value.text.substring(caret);
  return TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: start + replacement.length),
  );
}

/// Every finished filter word in [value] (one a space already follows) moved
/// out into [filters], and what is left of the text with the caret kept in place.
({List<SearchFilter> filters, TextEditingValue value}) takeFinishedFilters(
  TextEditingValue value,
) {
  final text = value.text;
  final caret = _caret(value);
  final filters = <SearchFilter>[];
  final kept = StringBuffer();
  var newCaret = caret;
  var at = 0;
  for (final span in searchWordSpans(text)) {
    final finished = span.end < text.length && span.end < caret;
    final filter = finished
        ? searchFilterFrom(text.substring(span.start, span.end))
        : null;
    if (filter == null) continue;
    filters.add(filter);
    kept.write(text.substring(at, span.start));
    // The space after the word goes with it, so no double space is left behind.
    final cut = span.end + 1;
    newCaret -= cut - span.start;
    at = cut;
  }
  if (filters.isEmpty) return (filters: filters, value: value);
  kept.write(text.substring(at));
  return (
    filters: filters,
    value: TextEditingValue(
      text: kept.toString(),
      selection: TextSelection.collapsed(offset: newCaret),
    ),
  );
}

int _caret(TextEditingValue value) {
  final offset = value.selection.extentOffset;
  return offset < 0 || offset > value.text.length ? value.text.length : offset;
}

/// The palette's search field and its chips, edited as one: a finished filter
/// word becomes a chip, a picked suggestion replaces the word that asked for
/// it, and Backspace at the very start takes the last chip back off.
class PaletteField {
  PaletteField({List<SearchFilter> filters = const [], required this.onEdited})
    : filters = [...filters];

  final List<SearchFilter> filters;

  /// Runs after every edit, typed or picked.
  final VoidCallback onEdited;

  final controller = TextEditingController();
  late final focusNode = FocusNode(onKeyEvent: _onKey);

  String get text => controller.text;

  /// The word before the caret, which suggestions complete.
  String get word => wordBeforeCaret(controller.value).word;

  /// The word being typed already names a filter key (`from:al`).
  bool get typingValue {
    final colon = word.indexOf(':');
    return colon > 0 && SearchKey.named(word.substring(0, colon)) != null;
  }

  /// For the field's `onChanged`: lifts finished filter words into chips.
  void typed() {
    final taken = takeFinishedFilters(controller.value);
    if (taken.filters.isNotEmpty) {
      controller.value = taken.value;
      filters.addAll(taken.filters);
    }
    onEdited();
  }

  /// Replaces the whole text, caret at its end.
  void setText(String text) {
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _edited();
  }

  /// [word] becomes the key being typed, ready for its value.
  void completeKey(String word) {
    controller.value = replaceWordBeforeCaret(controller.value, word);
    _edited();
  }

  /// [filter] becomes a chip in place of the word that was typing it.
  void add(SearchFilter filter) {
    controller.value = replaceWordBeforeCaret(controller.value, '');
    filters.add(filter);
    _edited();
  }

  void remove(SearchFilter filter) {
    filters.remove(filter);
    _edited();
  }

  void _edited() {
    typed();
    focusNode.requestFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final selection = controller.selection;
    final atStart = selection.isCollapsed && selection.baseOffset <= 0;
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.backspace &&
        atStart &&
        filters.isNotEmpty) {
      remove(filters.last);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void dispose() {
    controller.dispose();
    focusNode.dispose();
  }
}
