// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Windows taskbar button as a second place to be noticed: it flashes
/// while a message or ring waits for a window that is not focused, and carries
/// an unread count. Every other host makes each call a no-op, so a caller
/// needs no platform check.
library;

import 'package:flutter/services.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

import 'host_platform.dart';

const taskbarAttentionChannelName = 'slimm/taskbar_attention';

class TaskbarAttention {
  TaskbarAttention({MethodChannel? channel, bool? isWindows})
      : _channel = channel ?? const MethodChannel(taskbarAttentionChannelName),
        _isWindows = isWindows ?? isWindowsHost;

  final MethodChannel _channel;
  final bool _isWindows;

  /// Flashes the button until the window is focused; the runner stops it then.
  Future<void> flash() => _invoke('flash');

  /// Ends a flash that is still running, for an alert that went away unseen.
  Future<void> stop() => _invoke('stop');

  /// Shows [count] on the button's overlay icon; zero clears it.
  Future<void> setBadge(int count) => _invoke('badge', count < 0 ? 0 : count);

  Future<void> _invoke(String method, [Object? arguments]) async {
    if (!_isWindows) return;
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on PlatformException catch (error, stack) {
      AppLog.swallowed(LogTag.push, 'Taskbar $method failed', error, stack);
    } on MissingPluginException catch (error, stack) {
      AppLog.swallowed(LogTag.push, 'Taskbar $method failed', error, stack);
    }
  }
}
