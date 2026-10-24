// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Holds the OS window fullscreen with its title bar hidden while a video surface wants the whole display.
/// A no-op where there is no desktop shell.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag, ignoreError;

import 'desktop_window_port.dart' show DesktopWindowEventKind;
import 'desktop_window_shell.dart';

class WindowFullscreenHold {
  /// How many holds share one window, keyed by its chrome flag: the window leaves fullscreen only when the last lets go.
  static final _owners = Expando<int>();

  /// Whether the window was already fullscreen before the first hold, so the last release leaves it as found.
  static final _alreadyFullScreen = Expando<bool>();

  static int _heldAnywhere = 0;

  /// True while any hold keeps the window fullscreen; that is not a size the person chose, so it is never saved.
  static bool get anyHeld => _heldAnywhere > 0;

  @visibleForTesting
  static void debugReset() => _heldAnywhere = 0;

  /// [chromeHidden] is `fullscreenVideoActiveProvider`'s notifier, which the desktop chrome watches to step aside.
  WindowFullscreenHold(this._chromeHidden);

  final StateController<bool> _chromeHidden;
  bool _held = false;
  StreamSubscription<DesktopWindowEventKind>? _leaves;

  bool get held => _held;

  Future<void> enter() async {
    if (_held || !DesktopWindowShell.active) return;
    _held = true;
    _heldAnywhere++;
    final owners = (_owners[_chromeHidden] ?? 0) + 1;
    _owners[_chromeHidden] = owners;
    _leaves = DesktopWindowShell.port.events
        .where((kind) => kind == DesktopWindowEventKind.leaveFullScreen)
        .listen((_) => release());
    if (owners > 1) return;
    _chromeHidden.state = true;
    try {
      final port = DesktopWindowShell.port;
      _alreadyFullScreen[_chromeHidden] = await port.isFullScreen();
      if (!_held) return;
      await port.setFullScreen(true);
    } catch (error, stack) {
      if ((_owners[_chromeHidden] ?? 0) <= 1) _chromeHidden.state = false;
      AppLog.swallowed(
        LogTag.voice,
        'Could not make the window fullscreen; showing the video anyway',
        error,
        stack,
      );
    }
  }

  void release() {
    if (!_held) return;
    _held = false;
    _heldAnywhere--;
    unawaited(_leaves?.cancel());
    _leaves = null;
    final owners = (_owners[_chromeHidden] ?? 1) - 1;
    _owners[_chromeHidden] = owners;
    if (owners > 0) return;
    final port = DesktopWindowShell.port;
    final restoreFullScreen = _alreadyFullScreen[_chromeHidden] ?? false;
    scheduleMicrotask(() {
      // A hold that took over in the same frame (a remount) keeps the window as it is.
      if ((_owners[_chromeHidden] ?? 0) > 0) return;
      try {
        _chromeHidden.state = false;
      } on StateError catch (error, stack) {
        AppLog.swallowed(
          LogTag.voice,
          'The app is closing, so there is nothing to restore',
          error,
          stack,
        );
      }
      if (restoreFullScreen) return;
      unawaited(
        port
            .setFullScreen(false)
            .catchError(
              ignoreError(LogTag.platform, 'Could not leave window fullscreen'),
            ),
      );
    });
  }
}
