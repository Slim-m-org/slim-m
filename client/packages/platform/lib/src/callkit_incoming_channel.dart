// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What CallKit is doing with an incoming call it showed for a VoIP push,
/// bridged from native iOS.
///
/// The push is sealed to a key native code does not hold, so the native side
/// can only say "a call is ringing", "the user answered it" or "it is over",
/// never which channel it was. Dart matches that to the websocket's
/// `call.ringing` frame, which does carry the channel.
///
/// A VoIP push can launch the app, and the user can answer before Dart
/// exists, so the native side holds events until [takePending] asks; from then
/// on they arrive on [events]. See `ios/Runner/AppDelegate.swift`.
///
/// Android sends the same events from the incoming-call notification
/// (`CallKitBridge.kt`): [CallKitIncomingKind.answered] when its Answer opens
/// the app and [CallKitIncomingKind.declined] when its Decline is tapped.
library;

import 'dart:async';

import 'package:flutter/services.dart';

import 'host_platform.dart';
import 'method_channel_hub.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

const _channelName = 'top.npcserver.slimm/callkit_incoming';

enum CallKitIncomingKind { ringing, answered, ended, declined }

class CallKitIncomingEvent {
  const CallKitIncomingEvent(this.kind, this.callId,
      {this.callIdIsRingId = false});

  final CallKitIncomingKind kind;
  final String callId;

  /// True when [callId] is the server's ring id (Android), so an event may only act on that ring.
  final bool callIdIsRingId;

  static CallKitIncomingEvent? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final kind = CallKitIncomingKind.values
        .where((k) => k.name == raw['event'])
        .firstOrNull;
    final id = raw['id'];
    if (kind == null || id is! String) return null;
    return CallKitIncomingEvent(kind, id,
        callIdIsRingId: raw['ring_id'] == true);
  }
}

class CallKitIncomingChannel {
  CallKitIncomingChannel({MethodChannel? channel, bool? enabled})
      : _channel = channel ?? const MethodChannel(_channelName),
        _enabled = enabled ?? (isIOSHost || isAndroidHost) {
    if (_enabled) _calls = MethodChannelHub.of(_channel).calls.listen(_onCall);
  }

  final MethodChannel _channel;
  final bool _enabled;
  final _events = StreamController<CallKitIncomingEvent>.broadcast();
  StreamSubscription<MethodCall>? _calls;

  Stream<CallKitIncomingEvent> get events => _events.stream;

  void _onCall(MethodCall call) {
    if (call.method != 'onCallKitEvent') return;
    final event = CallKitIncomingEvent.tryParse(call.arguments);
    if (event != null) _events.add(event);
  }

  /// Events from before Dart listened, oldest first, consumed as read.
  ///
  /// Asking is also what tells the native side to switch to live delivery, so
  /// call it once, right after subscribing to [events].
  Future<List<CallKitIncomingEvent>> takePending() async {
    if (!_enabled) return const [];
    try {
      final raw = await _channel.invokeMethod<List<Object?>>('takePending');
      return (raw ?? const <Object?>[])
          .map(CallKitIncomingEvent.tryParse)
          .whereType<CallKitIncomingEvent>()
          .toList();
    } on PlatformException catch (error, stack) {
      AppLog.swallowed(LogTag.platform,
          'Could not read the pending incoming call', error, stack);
      return const [];
    } on MissingPluginException catch (error, stack) {
      AppLog.swallowed(LogTag.platform,
          'Could not read the pending incoming call', error, stack);
      return const [];
    }
  }

  /// Ends the system call [callId] named, so it does not outlive the ring or
  /// the in-app call it stood for. A no-op when it is already over.
  Future<void> endCall(String callId) async {
    if (!_enabled) return;
    try {
      await _channel.invokeMethod<void>('endCall', {'id': callId});
    } on PlatformException catch (error, stack) {
      AppLog.swallowed(
          LogTag.platform,
          'Could not end the system call; it may already be over',
          error,
          stack);
    } on MissingPluginException catch (error, stack) {
      AppLog.swallowed(
          LogTag.platform,
          'This build has no system call screen to end a call on',
          error,
          stack);
    }
  }

  Future<void> dispose() async {
    await _calls?.cancel();
    await _events.close();
  }
}
