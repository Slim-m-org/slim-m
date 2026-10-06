// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One answer to "is the window maximized" for every title bar widget, so a
/// double-click, a window manager shortcut and the maximize button all agree.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'desktop_window_port.dart';

class WindowMaximizedTracker extends ChangeNotifier {
  WindowMaximizedTracker(this._port) {
    _subscription = _port.events.listen(_onEvent);
    unawaited(refresh());
  }

  final DesktopWindowPort _port;
  late final StreamSubscription<DesktopWindowEventKind> _subscription;
  bool _maximized = false;
  bool _disposed = false;

  bool get maximized => _maximized;

  void _onEvent(DesktopWindowEventKind event) {
    if (event == DesktopWindowEventKind.maximize ||
        event == DesktopWindowEventKind.unmaximize) {
      unawaited(refresh());
    }
  }

  /// Re-queries the port rather than assuming, so a window manager that
  /// refuses a request cannot desync the icon from reality.
  Future<void> refresh() async {
    try {
      final value = await _port.isMaximized();
      if (_disposed || value == _maximized) return;
      _maximized = value;
      notifyListeners();
    } catch (_) {
      // An early-startup plugin failure leaves the icon at its default.
    }
  }

  Future<void> toggle() async {
    try {
      if (await _port.isMaximized()) {
        await _port.unmaximize();
      } else {
        await _port.maximize();
      }
    } catch (_) {
      // A WM refusal or plugin error leaves the icon as it was.
    }
    await refresh();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
