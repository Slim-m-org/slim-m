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
library;

import 'dart:async';

import 'package:flutter/services.dart';

import 'host_platform.dart';

const _channelName = 'top.npcserver.slimm/callkit_incoming';

enum CallKitIncomingKind { ringing, answered, ended }

class CallKitIncomingEvent {
  const CallKitIncomingEvent(this.kind, this.callId);

  final CallKitIncomingKind kind;
  final String callId;

  static CallKitIncomingEvent? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final kind = CallKitIncomingKind.values
        .where((k) => k.name == raw['event'])
        .firstOrNull;
    final id = raw['id'];
    if (kind == null || id is! String) return null;
    return CallKitIncomingEvent(kind, id);
  }
}

class CallKitIncomingChannel {
  CallKitIncomingChannel({MethodChannel? channel, bool? isIOS})
      : _channel = channel ?? const MethodChannel(_channelName),
        _isIOS = isIOS ?? isIOSHost {
    if (_isIOS) _channel.setMethodCallHandler(_onCall);
  }

  final MethodChannel _channel;
  final bool _isIOS;
  final _events = StreamController<CallKitIncomingEvent>.broadcast();

  Stream<CallKitIncomingEvent> get events => _events.stream;

  Future<void> _onCall(MethodCall call) async {
    if (call.method != 'onCallKitEvent') return;
    final event = CallKitIncomingEvent.tryParse(call.arguments);
    if (event != null) _events.add(event);
  }

  /// Events from before Dart listened, oldest first, consumed as read.
  ///
  /// Asking is also what tells the native side to switch to live delivery, so
  /// call it once, right after subscribing to [events].
  Future<List<CallKitIncomingEvent>> takePending() async {
    if (!_isIOS) return const [];
    try {
      final raw = await _channel.invokeMethod<List<Object?>>('takePending');
      return (raw ?? const <Object?>[])
          .map(CallKitIncomingEvent.tryParse)
          .whereType<CallKitIncomingEvent>()
          .toList();
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  /// Ends the system call [callId] named, so it does not outlive the ring or
  /// the in-app call it stood for. A no-op when it is already over.
  Future<void> endCall(String callId) async {
    if (!_isIOS) return;
    try {
      await _channel.invokeMethod<void>('endCall', {'id': callId});
    } on PlatformException {
      // Best-effort: the call may already be gone.
    } on MissingPluginException {
      // No native side to end anything on.
    }
  }

  Future<void> dispose() => _events.close();
}
