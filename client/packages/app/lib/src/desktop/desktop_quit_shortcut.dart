// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A second, independent route to the same quit [WindowMenuButton] offers:
/// a global Ctrl+Q, reachable with no tray, with nothing needing focus, and
/// with no title bar to open first - the redundancy is deliberate, the same
/// shape this project already accepted for the screen-share stop path.
///
/// Registered through [HardwareKeyboard] directly rather than through the
/// app's own remappable shortcut table (`platform/lib/src/shortcuts.dart`).
/// That table's one binding site, `home_shell.dart`'s `CallbackShortcuts`,
/// only fires for a focused descendant of the shell - and several screens
/// (settings among them) are separate top-level routes that unmount the
/// shell entirely, per `router.dart`'s own top-level `GoRoute` list, so a
/// binding there would silently stop reaching the app on exactly the
/// screens this guarantee cannot afford to have a hole on.
/// [HardwareKeyboard.addHandler] is the API's own documented answer for
/// that case: notified regardless of what, if anything, currently holds
/// focus.
library;

import 'dart:async';

import 'package:flutter/services.dart';

import 'close_behavior.dart';
import 'desktop_window_shell.dart' show DesktopWindowShell;

class DesktopQuitShortcut {
  DesktopQuitShortcut(this._shell);

  final DesktopWindowShell _shell;
  bool _registered = false;

  /// A no-op on mobile and web, matching every other call
  /// [DesktopWindowShell] makes from `main.dart`. macOS keeps its own
  /// `Cmd+Q` convention once scaffolded, per decision 0012, so this binds
  /// only where the window controls it complements actually render today,
  /// never introducing a second, conflicting quit gesture there.
  ///
  /// [platform] defaults to the real, live [currentDesktopPlatform] and
  /// exists as a parameter only so a test can exercise every branch from
  /// this Linux dev box, the same seam `shortcuts.dart`'s own `forWeb`
  /// parameter already uses for its platform-conditional default.
  void register({DesktopPlatform? platform}) {
    final resolved = platform ?? currentDesktopPlatform();
    if (resolved == null || resolved == DesktopPlatform.macOS) return;
    _registered = true;
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
  }

  /// Takes the handler off [HardwareKeyboard], a process singleton that would
  /// otherwise keep firing into a discarded shortcut.
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    _registered = false;
  }

  bool _onKeyEvent(KeyEvent event) {
    if (!_registered || event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.keyQ) return false;
    final keyboard = HardwareKeyboard.instance;
    if (!keyboard.isControlPressed) return false;
    // Ctrl+Q only: AltGr layouts type a character on Ctrl+Alt+Q, and the others are another app's chord.
    if (keyboard.isShiftPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return false;
    }
    unawaited(_shell.quit(_shell.port));
    return true;
  }
}
