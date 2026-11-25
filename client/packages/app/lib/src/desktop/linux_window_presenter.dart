// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Raises the window for a banner click on Linux, with the activation token the
/// notification server sent, which Wayland needs before it grants focus.
library;

import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;
import 'package:slimm_api/api.dart' show AppLog, LogTag;
import 'package:slimm_platform/platform.dart' show LinuxActivationToken;

class LinuxWindowPresenter {
  LinuxWindowPresenter({MethodChannel? channel, LinuxActivationToken? tokens})
    : _channel = channel ?? const MethodChannel(_name),
      _tokens = tokens ?? LinuxActivationToken();

  /// Named to match `linux_window_present_channel.cc`.
  static const _name = 'top.npcserver.slimm/linux_window_present';

  final MethodChannel _channel;
  final LinuxActivationToken _tokens;

  /// Starts collecting the tokens notification servers send.
  void start() => _tokens.listen();

  /// Presents the window with the click's token; false when none arrived or the runner refused.
  Future<bool> present() async {
    final token = _tokens.take();
    if (token == null) return false;
    try {
      return await _channel.invokeMethod<bool>('present', token) ?? false;
    } on PlatformException catch (error, stack) {
      AppLog.swallowed(
        LogTag.platform,
        'Could not present the window',
        error,
        stack,
      );
    } on MissingPluginException catch (error, stack) {
      AppLog.swallowed(
        LogTag.platform,
        'Could not present the window',
        error,
        stack,
      );
    }
    return false;
  }
}
