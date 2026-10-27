// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Android's foreground service for a live call and for screen sharing.
///
/// Without it Android silences the microphone and stops screen capture once
/// the app is backgrounded; the service also owns the ongoing-call
/// notification. Rides the same native plugin as [CallNotifications].
library;

import 'package:flutter/services.dart';

import 'host_platform.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

const _channelName = 'top.npcserver.slimm/calls';

/// What the service should currently cover; all false means stopped.
class CallServiceState {
  const CallServiceState({
    this.call = false,
    this.camera = false,
    this.share = false,
  });

  final bool call;
  final bool camera;
  final bool share;

  bool get active => call || share;

  @override
  bool operator ==(Object other) =>
      other is CallServiceState &&
      other.call == call &&
      other.camera == camera &&
      other.share == share;

  @override
  int get hashCode => Object.hash(call, camera, share);

  @override
  String toString() =>
      'CallServiceState(call: $call, camera: $camera, share: $share)';
}

/// A clean no-op everywhere but Android.
class CallService {
  CallService({MethodChannel? channel, bool? isAndroid})
      : _channel = channel ?? const MethodChannel(_channelName),
        _isAndroid = isAndroid ?? isAndroidHost;

  final MethodChannel _channel;
  final bool _isAndroid;
  CallServiceState _last = const CallServiceState();

  bool get isSupported => _isAndroid;

  /// Moves the service to [state], starting or stopping it as needed; a
  /// repeat of the last state sends nothing.
  Future<void> update(CallServiceState state) async {
    if (!_isAndroid || state == _last) return;
    _last = state;
    try {
      await _channel.invokeMethod<void>('updateCallService', {
        'call': state.call,
        'camera': state.camera,
        'share': state.share,
      });
    } on PlatformException catch (error, stack) {
      AppLog.swallowed(LogTag.voice,
          'Could not update the call foreground service', error, stack);
    } on MissingPluginException catch (error, stack) {
      AppLog.swallowed(LogTag.voice,
          'This build has no call foreground service', error, stack);
    }
  }
}
