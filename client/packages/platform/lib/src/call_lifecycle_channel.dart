// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Bridges a voice call's lifecycle to iOS CallKit.
///
/// A call joined from this app's own UI never reaches `CXProvider` unless
/// something tells it to: `VoipCallHandler.swift`'s reporting only ever runs
/// from an inbound VoIP push, so a call started from a tap on Join gets none
/// of the background execution grant CallKit gives a call it holds. This
/// channel is the missing half of https://github.com/NC1107/slim-m/issues/212
/// - the native side (`VoiceCallReporter.swift`) requests a
/// `CXStartCallAction`, reports it connecting and then connected, and reports
/// it ended; a hangup from the system call UI comes back the other way as
/// [endCallRequests].
///
/// `docs/research/appstore.md` and its adversarial review already ruled out
/// `UIBackgroundModes: audio` as a shortcut for this: it is a named App Store
/// 2.5.4 rejection risk when used to keep a call alive rather than for
/// genuine continuous playback. `voip` plus an actually-reported CallKit call
/// is the compliant path, and CallKit itself is what grants the execution,
/// which is the entire point of reporting the call at all.
library;

import 'dart:async';

import 'package:flutter/services.dart';

import 'host_platform.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

const _channelName = 'top.npcserver.slimm/call_lifecycle';

/// A clean no-op everywhere but iOS: CallKit does not exist elsewhere, and
/// Android's own incoming-call surface is [CallNotifications], not this.
class CallLifecycleChannel {
  CallLifecycleChannel({MethodChannel? channel, bool? isIOS})
      : _channel = channel ?? const MethodChannel(_channelName),
        _isIOS = isIOS ?? isIOSHost {
    // Guarded, or a non-iOS test needs a binary messenger just to construct this.
    if (_isIOS) _channel.setMethodCallHandler(_onCall);
  }

  final MethodChannel _channel;
  final bool _isIOS;
  final _endCalls = StreamController<void>.broadcast();

  /// Fires whenever the system call UI ends this call (Dynamic Island, the
  /// lock screen, and so on). CallKit has already told the native side and
  /// fulfilled its own action by the time this arrives, so a listener's job
  /// is only to leave the room, never to decide whether the hangup happens.
  Stream<void> get endCallRequests => _endCalls.stream;

  Future<void> _onCall(MethodCall call) async {
    if (call.method == 'endCall') _endCalls.add(null);
  }

  /// Reports a call this app's own UI joined, so CallKit grants it the same
  /// background execution an inbound VoIP push already gets.
  ///
  /// [callId] must be a UUID string; slim-m channel ids already are one, so
  /// the channel being joined is reused rather than minting a second id this
  /// side would have to keep in step with the native one.
  Future<void> callStarted({
    required String callId,
    required String displayName,
  }) async {
    if (!_isIOS) return;
    try {
      await _channel.invokeMethod<void>('callStarted', {
        'callId': callId,
        'displayName': displayName,
      });
    } on PlatformException catch (error, stack) {
      AppLog.swallowed(
          LogTag.voice,
          'No CallKit call to report; the room itself is unaffected',
          error,
          stack);
    } on MissingPluginException catch (error, stack) {
      AppLog.swallowed(LogTag.voice, 'on call failed, ignored', error, stack);
      // As above: a build with no native handler for this channel.
    }
  }

  /// The room actually connected, following [callStarted].
  Future<void> callConnected() async {
    if (!_isIOS) return;
    try {
      await _channel.invokeMethod<void>('callConnected');
    } on PlatformException catch (error, stack) {
      AppLog.swallowed(
          LogTag.voice,
          'Nothing reported yet, or CallKit unavailable; the state is unaffected',
          error,
          stack);
    } on MissingPluginException catch (error, stack) {
      AppLog.swallowed(
          LogTag.voice, 'call connected failed, ignored', error, stack);
      // As above.
    }
  }

  /// The call ended, from this side. Safe to call with nothing reported.
  Future<void> callEnded() async {
    if (!_isIOS) return;
    try {
      await _channel.invokeMethod<void>('callEnded');
    } on PlatformException catch (error, stack) {
      AppLog.swallowed(
          LogTag.voice,
          'Nothing reported, which is the state this call wanted anyway',
          error,
          stack);
    } on MissingPluginException catch (error, stack) {
      AppLog.swallowed(
          LogTag.voice, 'call ended failed, ignored', error, stack);
      // As above.
    }
  }

  void dispose() {
    unawaited(_endCalls.close());
  }
}
