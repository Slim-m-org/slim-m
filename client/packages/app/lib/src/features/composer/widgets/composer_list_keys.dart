// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The composer's list keys: Tab and Shift+Tab move a list item a level,
/// Backspace on an empty item leaves the list.
///
/// Tab is claimed only on a list line, so everywhere else it still moves focus
/// along. On a list line it would otherwise trap the keyboard, so Escape hands
/// Tab back until the next ordinary key: Escape, then Tab, leaves the box.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'composer_list_indent.dart';

class ComposerListKeys {
  bool _tabReleased = false;

  static final Set<LogicalKeyboardKey> _modifiers = {
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
  };

  /// Handled only when the key changed or deliberately held the list as it
  /// was; ignored lets the field and the focus system have it.
  KeyEventResult handle(KeyEvent event, TextEditingController controller) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (_modifiers.contains(key)) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.escape) {
      _tabReleased = true;
      return KeyEventResult.ignored;
    }
    final released = _tabReleased && key == LogicalKeyboardKey.tab;
    if (!released) _tabReleased = false;

    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isMetaPressed ||
        keyboard.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final TextEditingValue? next;
    if (key == LogicalKeyboardKey.tab && !released) {
      final value = controller.value;
      next = keyboard.isShiftPressed ? outdentList(value) : indentList(value);
    } else if (key == LogicalKeyboardKey.backspace) {
      next = leaveEmptyItem(controller.value);
    } else {
      next = null;
    }
    if (next == null) return KeyEventResult.ignored;
    controller.value = next;
    return KeyEventResult.handled;
  }
}
