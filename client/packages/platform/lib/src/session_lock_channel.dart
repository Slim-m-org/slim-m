// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Windows tells the runner when the session locks, the machine sleeps or the
/// user switches away, and when they come back. None of that changes the
/// window's lifecycle state while it stays visible, so the app lock needs this
/// to start its grace window. Every other host never calls back.
library;

import 'package:flutter/services.dart';

import 'host_platform.dart';

const sessionLockChannelName = 'slimm/session_lock';

class SessionLockChannel {
  SessionLockChannel({MethodChannel? channel, bool? isWindows})
      : _channel = channel ?? const MethodChannel(sessionLockChannelName),
        _isWindows = isWindows ?? isWindowsHost;

  final MethodChannel _channel;
  final bool _isWindows;

  /// Calls [away] when the session locks or the machine suspends, [back] on the way back in.
  void listen({required void Function() away, required void Function() back}) {
    if (!_isWindows) return;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'away':
          away();
        case 'back':
          back();
      }
    });
  }
}
