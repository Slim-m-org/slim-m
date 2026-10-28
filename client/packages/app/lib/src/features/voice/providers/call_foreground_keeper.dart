// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Decides when Android's call foreground service runs, from the call's own
/// state, so every join, leave, drop, camera toggle and share reports alike.
library;

import 'dart:async';

import 'package:slimm_api/api.dart' show AppLog, LogTag;
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

class CallForegroundKeeper {
  CallForegroundKeeper({
    CallService? service,
    Future<bool> Function()? requestCapturePermission,
    Future<void> Function()? requestNotifications,
  }) : _service = service ?? CallService(),
       _requestCapture =
           requestCapturePermission ?? requestScreenCapturePermission,
       _requestNotifications = requestNotifications;

  final CallService _service;
  final Future<bool> Function() _requestCapture;
  final Future<void> Function()? _requestNotifications;

  bool _connected = false;
  bool _camera = false;
  bool _sharing = false;
  bool _shareStarting = false;
  bool _askedNotifications = false;

  void sessionState(VoiceSessionState s) {
    _connected = s == VoiceSessionState.connected;
    if (s == VoiceSessionState.idle || s == VoiceSessionState.failed) {
      _camera = false;
      _sharing = false;
      _shareStarting = false;
    }
    if (_connected) unawaited(_askNotificationsOnce());
    _push();
  }

  /// The local participant's camera and share as the room reports them.
  void media({required bool camera, required bool sharing}) {
    _camera = camera;
    if (!_shareStarting) _sharing = sharing;
    _push();
  }

  /// Gets the capture consent and starts the share service ahead of
  /// `getDisplayMedia`; false means the share must not go ahead.
  Future<bool> beforeShare() async {
    if (!_service.isSupported) return true;
    if (!await _requestCapture()) return false;
    _shareStarting = true;
    _sharing = true;
    await _service.update(_state);
    return true;
  }

  /// The share request finished, started or not.
  void shareSettled({required bool started}) {
    _shareStarting = false;
    _sharing = started;
    _push();
  }

  CallServiceState get _state => CallServiceState(
    call: _connected,
    camera: _connected && _camera,
    share: _connected && _sharing,
  );

  void _push() => unawaited(_service.update(_state));

  Future<void> _askNotificationsOnce() async {
    final ask = _requestNotifications;
    if (ask == null || _askedNotifications || !_service.isSupported) return;
    _askedNotifications = true;
    try {
      await ask();
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.voice,
        'Could not ask for the notification permission',
        error,
        stack,
      );
    }
  }
}
