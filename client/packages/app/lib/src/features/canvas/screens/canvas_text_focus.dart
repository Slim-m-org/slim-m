// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keeps canvas key bindings out of text fields: a key typed into the note
/// editor, a mention or the emoji picker belongs to that field alone.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Whether the focused widget is a text input, wherever it sits in the tree.
bool textInputHasFocus() {
  final focus = FocusManager.instance.primaryFocus?.context;
  if (focus == null) return false;
  return focus.widget is EditableText ||
      focus.findAncestorWidgetOfExactType<EditableText>() != null;
}

/// A shortcut that never fires while a text input has focus.
class UnlessTyping implements ShortcutActivator {
  const UnlessTyping(this.inner);

  final ShortcutActivator inner;

  @override
  Iterable<LogicalKeyboardKey>? get triggers => inner.triggers;

  @override
  bool accepts(KeyEvent event, HardwareKeyboard state) =>
      !textInputHasFocus() && inner.accepts(event, state);

  @override
  String debugDescribeKeys() => inner.debugDescribeKeys();
}

/// [bindings] with every key wrapped in [UnlessTyping].
Map<ShortcutActivator, VoidCallback> unlessTyping(
  Map<ShortcutActivator, VoidCallback> bindings,
) => {
  for (final entry in bindings.entries) UnlessTyping(entry.key): entry.value,
};
