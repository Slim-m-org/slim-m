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

  /// Calls [away] when the session locks or the machine suspends, [back] once
  /// the last of those has ended.
  ///
  /// The runner names the reason with each call, so a wake while the session
  /// is still locked does not read as the person being back.
  void listen({required void Function() away, required void Function() back}) {
    if (!_isWindows) return;
    final reasons = <String>{};
    _channel.setMethodCallHandler((call) async {
      final reason = call.arguments as String? ?? 'session';
      switch (call.method) {
        case 'away':
          final first = reasons.isEmpty;
          reasons.add(reason);
          if (first) away();
        case 'back':
          reasons.remove(reason);
          if (reasons.isEmpty) back();
      }
    });
  }
}
