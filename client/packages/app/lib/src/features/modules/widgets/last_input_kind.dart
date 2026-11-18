// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether the user's last input was a key rather than a pointer, app-wide.
///
/// The CSS focus-visible rule decides from how the user last interacted, not
/// from how focus arrived, so focus Flutter restores on its own stays quiet.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

class LastInputKind {
  LastInputKind._();

  static final instance = LastInputKind._();

  final _keyboard = ValueNotifier<bool>(false);
  int _users = 0;

  ValueListenable<bool> get keyboard => _keyboard;

  void add(VoidCallback listener) {
    if (_users++ == 0) {
      GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
      HardwareKeyboard.instance.addHandler(_onKey);
    }
    _keyboard.addListener(listener);
  }

  void remove(VoidCallback listener) {
    _keyboard.removeListener(listener);
    if (--_users > 0) return;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    HardwareKeyboard.instance.removeHandler(_onKey);
    _keyboard.value = false;
  }

  void _onPointer(PointerEvent event) {
    if (event is PointerDownEvent) _keyboard.value = false;
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyUpEvent && _navigates(event)) _keyboard.value = true;
    return false;
  }

  /// Only keys that move focus or act on a grid count: a held push-to-talk
  /// key is not navigation, and alt-tab and shortcuts are not either.
  bool _navigates(KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isAltPressed ||
        keyboard.isControlPressed ||
        keyboard.isMetaPressed) {
      return false;
    }
    return _navigation.contains(event.logicalKey);
  }

  static final _navigation = {
    LogicalKeyboardKey.tab,
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.space,
    LogicalKeyboardKey.escape,
    LogicalKeyboardKey.home,
    LogicalKeyboardKey.end,
    LogicalKeyboardKey.pageUp,
    LogicalKeyboardKey.pageDown,
  };
}
