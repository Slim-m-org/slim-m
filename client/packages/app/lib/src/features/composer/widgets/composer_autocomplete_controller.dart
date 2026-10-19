// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The open `@`, `#`, `:` or `/` trigger and which of its offers is current.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'composer_autocomplete_items.dart';
import 'composer_autocomplete_query.dart';

class ComposerAutocompleteController extends ChangeNotifier {
  AutocompleteQuery? _query;
  List<AutocompleteSuggestion> _suggestions = const [];
  int _selected = 0;

  AutocompleteQuery? get query => _query;
  List<AutocompleteSuggestion> get suggestions => _suggestions;
  int get selected => _selected;

  /// Whether the list is showing, and so owns the arrow, Tab and Enter keys.
  bool get isOpen => _query != null && _suggestions.isNotEmpty;

  /// Silent: the offers are rebuilt on every build from watched providers.
  void setSuggestions(List<AutocompleteSuggestion> suggestions) =>
      _suggestions = suggestions;

  /// Back to row one on a new trigger, so Enter takes whatever ranks first.
  void setQuery(AutocompleteQuery? query) {
    if (query == _query) return;
    _query = query;
    _selected = 0;
    notifyListeners();
  }

  void resetSelection() => _selected = 0;

  void select(int index) {
    _selected = index;
    notifyListeners();
  }

  void dismiss() {
    if (_query == null) return;
    _query = null;
    _selected = 0;
    notifyListeners();
  }

  /// Replaces the trigger span with the choice and closes the list; a `/gif`
  /// choice clears the field and hands over to [onGif] instead.
  void accept(
    AutocompleteSuggestion suggestion,
    TextEditingController text, {
    required VoidCallback onGif,
    required VoidCallback onInserted,
  }) {
    final query = _query;
    if (query == null) return;
    if (suggestion.label == '/gif') {
      dismiss();
      text.clear();
      onGif();
      return;
    }
    text.value = TextEditingValue(
      text: text.text.replaceRange(query.start, query.end, suggestion.insert),
      selection: TextSelection.collapsed(
        offset: query.start + suggestion.insert.length,
      ),
    );
    onInserted();
    dismiss();
  }

  /// Escape, the arrows, and Tab or Enter to accept. Call only while [isOpen].
  KeyEventResult handleKey(
    KeyEvent event, {
    required void Function(AutocompleteSuggestion) onAccept,
  }) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      dismiss();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      select((_selected + 1) % _suggestions.length);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      select((_selected - 1 + _suggestions.length) % _suggestions.length);
      return KeyEventResult.handled;
    }
    // Both accept; Enter would otherwise send the half-typed trigger.
    if (key == LogicalKeyboardKey.tab || key == LogicalKeyboardKey.enter) {
      final keyboard = HardwareKeyboard.instance;
      // A held modifier is a global shortcut (Ctrl/Cmd+Tab cycles channels), not an accept.
      if (keyboard.isShiftPressed ||
          keyboard.isControlPressed ||
          keyboard.isMetaPressed) {
        return KeyEventResult.ignored;
      }
      onAccept(_suggestions[_selected]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }
}
