// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Holds the OS window fullscreen with its title bar hidden for as long as a
/// video surface wants the whole display, and gives it back on release.
///
/// Shared by the fullscreen video route and the canvas's focused tile so the
/// two cover the display the same way. A no-op where there is no desktop shell.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag, ignoreError;

import 'desktop_window_shell.dart';

class WindowFullscreenHold {
  /// How many holds share one window, keyed by its chrome flag: the window leaves fullscreen only when the last lets go.
  static final _owners = Expando<int>();

  /// [chromeHidden] is `fullscreenVideoActiveProvider`'s notifier, which the desktop chrome watches to step aside.
  WindowFullscreenHold(this._chromeHidden);

  final StateController<bool> _chromeHidden;
  bool _held = false;

  bool get held => _held;

  Future<void> enter() async {
    if (_held || !DesktopWindowShell.active) return;
    _held = true;
    final owners = (_owners[_chromeHidden] ?? 0) + 1;
    _owners[_chromeHidden] = owners;
    if (owners > 1) return;
    _chromeHidden.state = true;
    try {
      await DesktopWindowShell.port.setFullScreen(true);
    } catch (error, stack) {
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
    final owners = (_owners[_chromeHidden] ?? 1) - 1;
    _owners[_chromeHidden] = owners;
    if (owners > 0) return;
    final port = DesktopWindowShell.port;
    scheduleMicrotask(() {
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
