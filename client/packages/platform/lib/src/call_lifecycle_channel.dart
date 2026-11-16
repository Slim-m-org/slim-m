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

import 'call_system_event.dart';
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
  final _systemEvents = StreamController<String>.broadcast();

  /// Fires whenever the system call UI ends this call (Dynamic Island, the
  /// lock screen, and so on). CallKit has already told the native side and
  /// fulfilled its own action by the time this arrives, so a listener's job
  /// is only to leave the room, never to decide whether the hangup happens.
  Stream<void> get endCallRequests => _endCalls.stream;

  /// Each CallKit step and its result, and every interruption or route
  /// change of the shared audio session, as a line for the call's
  /// diagnostics; see [describeCallSystemEvent]. Only records, never acts.
  Stream<String> get systemEvents => _systemEvents.stream;

  Future<void> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'endCall':
        _endCalls.add(null);
      case 'callEvent':
        final args = call.arguments;
        final line = args is Map ? describeCallSystemEvent(args) : null;
        if (line != null && !_systemEvents.isClosed) _systemEvents.add(line);
    }
  }

  /// The shared audio session right now as one phrase, or null off iOS or
  /// on a build whose native side cannot read it; see [describeAudioSession].
  Future<String?> audioSessionLine() async {
    if (!_isIOS) return null;
    try {
      final session = await _channel.invokeMethod<Map<Object?, Object?>>(
        'audioSession',
      );
      return session == null ? null : describeAudioSession(session);
    } on PlatformException catch (error, stack) {
      AppLog.swallowed(LogTag.voice, 'No audio session read', error, stack);
    } on MissingPluginException catch (error, stack) {
      AppLog.swallowed(LogTag.voice, 'No audio session reader', error, stack);
    }
    return null;
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
          'The system call screen is not available; the call itself is unaffected',
          error,
          stack);
    } on MissingPluginException catch (error, stack) {
      AppLog.swallowed(LogTag.voice, 'Could not tell the system a call started',
          error, stack);
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
          'The system call screen is not available; the call itself is unaffected',
          error,
          stack);
    } on MissingPluginException catch (error, stack) {
      AppLog.swallowed(LogTag.voice,
          'Could not tell the system a call connected', error, stack);
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
          'The system call screen is not available; nothing to end',
          error,
          stack);
    } on MissingPluginException catch (error, stack) {
      AppLog.swallowed(
          LogTag.voice, 'Could not tell the system a call ended', error, stack);
      // As above.
    }
  }

  void dispose() {
    unawaited(_endCalls.close());
    unawaited(_systemEvents.close());
  }
}
