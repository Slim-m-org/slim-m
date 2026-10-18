// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which channel a tapped push notification came from, bridged from native
/// iOS.
///
/// The id is not something this side could work out for itself. It arrives
/// inside the sealed envelope, which only the notification service extension
/// holds the key to open; that extension writes it into the delivered
/// notification's `userInfo`, and `AppDelegate.swift` reads it back out when
/// somebody taps. See `ios/NotificationService/PushEnvelope.swift` for the
/// keys and why routing is attached whether or not the envelope also carried
/// a content preview.
///
/// A tap is the ordinary way a killed app gets launched, so it routinely
/// happens before there is any Dart to tell. The native side holds the last
/// one until it is asked for, which is what [takeInitial] asks; a tap while
/// the app is already running arrives on [taps] instead. Both are needed and
/// neither subsumes the other.
///
/// iOS only, and that is a limitation rather than a choice: on Android the
/// envelope is still sealed to a key nothing on the device opens, so there is
/// no channel id to route to. [taps] is simply empty there, and
/// [takeInitial] answers null, so a caller needs no platform check of its
/// own.
library;

import 'dart:async';

import 'package:flutter/services.dart';

import 'host_platform.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

const _channelName = 'top.npcserver.slimm/push_tap';

/// Reports the channel a push notification tap wants opened.
class NotificationTapChannel {
  NotificationTapChannel({MethodChannel? channel, bool? isIOS})
      : _channel = channel ?? const MethodChannel(_channelName),
        _isIOS = isIOS ?? isIOSHost {
    if (_isIOS) _channel.setMethodCallHandler(_onCall);
  }

  final MethodChannel _channel;
  final bool _isIOS;
  final _taps = StreamController<String>.broadcast();

  /// Taps arriving while the app is already running.
  Stream<String> get taps => _taps.stream;

  Future<void> _onCall(MethodCall call) async {
    if (call.method != 'onNotificationTap') return;
    final channelId = call.arguments;
    if (channelId is String && channelId.isNotEmpty) _taps.add(channelId);
  }

  /// The tap that launched this app, if one did, consumed as it is read.
  ///
  /// Consuming is the whole point: a tap is a one-time instruction to go
  /// somewhere, and one that answered every launch would keep dragging the
  /// user back to a channel they had since navigated away from.
  ///
  /// Both failure paths answer null rather than throwing: routing is a
  /// convenience on top of a notification already shown, and nothing here is
  /// worth failing a launch over.
  Future<String?> takeInitial() async {
    if (!_isIOS) return null;
    try {
      final channelId = await _channel.invokeMethod<String>('takeInitialTap');
      return (channelId != null && channelId.isNotEmpty) ? channelId : null;
    } on PlatformException catch (error, stack) {
      AppLog.swallowed(LogTag.push,
          'Could not read the notification that opened the app', error, stack);
      return null;
    } on MissingPluginException catch (error, stack) {
      AppLog.swallowed(LogTag.push,
          'Could not read the notification that opened the app', error, stack);
      return null;
    }
  }

  Future<void> dispose() => _taps.close();
}
