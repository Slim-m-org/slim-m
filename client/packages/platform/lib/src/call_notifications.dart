// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Shows Android's incoming-call notification for a content-free `call`
/// push - the Android counterpart to iOS reporting a call to CallKit (see
/// `VoipCallHandler.swift`).
///
/// A `MethodChannel` rather than a call into `LocalNotifications`: that
/// class's plugin has no `Notification.CallStyle` support, so the native
/// side here is this app's own `CallNotificationPlugin`, registered as a
/// real Flutter plugin (see this package's `pubspec.yaml` and
/// `android/src/main/kotlin/.../CallNotificationPlugin.kt`) rather than a
/// bare channel wired up in `MainActivity` - the latter would be invisible
/// to the headless `FlutterEngine` `firebase_messaging` runs its background
/// isolate in, which is exactly where an Android call push arrives.
library;

import 'package:flutter/services.dart';

import 'host_platform.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

const _channelName = 'top.npcserver.slimm/calls';

/// Displays this app's incoming-call notification on Android.
///
/// A clean no-op everywhere else: iOS reports the call to CallKit instead,
/// and neither Linux nor a browser has a call-notification surface at all.
class CallNotifications {
  CallNotifications({MethodChannel? channel, bool? isAndroid})
      : _channel = channel ?? const MethodChannel(_channelName),
        _isAndroid = isAndroid ?? isAndroidHost;

  final MethodChannel _channel;
  final bool _isAndroid;

  /// Shows, or replaces, the incoming-call notification for [callId], naming
  /// [callerName]. A repeat call sharing one [callId] updates the
  /// notification already on screen instead of stacking a second one.
  Future<void> showIncomingCall({
    required String callId,
    required String callerName,
  }) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<void>('showIncomingCall', {
        'callId': callId,
        'callerName': callerName,
      });
    } on PlatformException catch (error, stack) {
      AppLog.swallowed(
          LogTag.voice,
          'This runs on the FCM background isolate\'s top-level handler, which has no outer catch; an uncaught throw...',
          error,
          stack);
    } on MissingPluginException catch (error, stack) {
      AppLog.swallowed(
          LogTag.voice,
          'A build or isolate with no native CallNotificationPlugin registered; there is no notification surface to reach',
          error,
          stack);
    }
  }

  /// Takes down every incoming-call notification and ringing Telecom
  /// connection, for a push saying the ring has ended. Cancelled by channel
  /// on the native side because the notification id is derived from a call
  /// id this push does not carry.
  Future<void> endIncomingCalls() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<void>('endIncomingCalls');
    } on PlatformException catch (error, stack) {
      AppLog.swallowed(
          LogTag.voice, 'end incoming calls failed, ignored', error, stack);
      // Same background-isolate reasoning as showIncomingCall: a missed teardown is better than an uncaught throw.
    } on MissingPluginException catch (error, stack) {
      AppLog.swallowed(
          LogTag.voice,
          'No native CallNotificationPlugin in this build or isolate; there is nothing ringing to end',
          error,
          stack);
    }
  }
}
