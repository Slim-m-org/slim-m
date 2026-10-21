// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The composer field's key interception, one place for every shortcut.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';

import 'composer_autocomplete_controller.dart';
import 'composer_autocomplete_items.dart';
import 'composer_clipboard_paste.dart';
import 'composer_list_keys.dart';

class ComposerKeyHandler {
  ComposerKeyHandler({
    required this.text,
    required this.autocomplete,
    required this.onPasteChord,
    required this.onEditLast,
    required this.onAccept,
  });

  final TextEditingController text;
  final ComposerAutocompleteController autocomplete;
  final VoidCallback onPasteChord;
  final Future<void> Function() onEditLast;
  final void Function(AutocompleteSuggestion) onAccept;
  final ComposerListKeys _listKeys = ComposerListKeys();

  /// Intercepts the keys the list needs on the field's own focus node, since text editing handles arrows above the field and an ancestor would run after the caret moved.
  /// The paste check sits above the autocomplete guard and never returns `handled`, so Flutter's own text paste is untouched.
  KeyEventResult handle(FocusNode node, KeyEvent event) {
    if (isClipboardPasteChord(event)) onPasteChord();
    // Up in an empty composer edits the caller's last message; with text typed it must move the caret as normal instead.
    if (event is KeyDownEvent &&
        text.text.isEmpty &&
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      unawaited(onEditLast());
      return KeyEventResult.handled;
    }
    if (!autocomplete.isOpen) return _listKeys.handle(event, text);
    return autocomplete.handleKey(event, onAccept: onAccept);
  }
}
