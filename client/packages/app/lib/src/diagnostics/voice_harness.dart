// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Joins a voice channel at launch so the voice quality harness can drive the
/// real desktop capture chain without clicking through the UI.
///
/// Reachable only from a build made with `--dart-define=SLIMM_VOICE_HARNESS=true`:
/// the flag is a compile-time constant, so every other build drops this code.
/// See docs/research/voice-quality-harness-v2.md.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart' show VoiceSessionState;

import '../features/voice/providers/voice_controller.dart';
import '../providers/providers.dart';

const bool kVoiceHarness = bool.fromEnvironment('SLIMM_VOICE_HARNESS');

/// The line prefix the Python harness reads as a failed join, which it retries once.
const joinFailedMarker = 'SLIMM_HARNESS join-failed';

const _channelFlag = '--voice-harness-channel=';
const _signInWait = Duration(seconds: 90);
const _joinWait = Duration(seconds: 60);

/// The channel id passed as `--voice-harness-channel=<id>`, if any.
String? harnessChannel(List<String> args) {
  for (final arg in args) {
    if (arg.startsWith(_channelFlag)) return arg.substring(_channelFlag.length);
  }
  return null;
}

/// Waits for the restored session, joins [channel], and prints one line per
/// second about the capture gate so the harness can read it from stdout.
Future<void> joinHarnessChannel(
  ProviderContainer Function() container,
  String channel,
) async {
  final deadline = DateTime.now().add(_signInWait);
  while (!container().read(sessionProvider).isSignedIn) {
    if (DateTime.now().isAfter(deadline)) {
      debugPrint('$joinFailedMarker signin-timeout');
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  final voice = container().read(voiceControllerProvider.notifier);
  await voice.join(channel);
  final failure = await _joinFailure(container);
  if (failure != null) {
    debugPrint('$joinFailedMarker $failure');
    return;
  }
  debugPrint('SLIMM_HARNESS joined $channel');
  _logGate(voice, container);
}

/// Null once the call is connected; otherwise what it ended in, since
/// [VoiceController.join] reports a failure in state rather than throwing.
Future<String?> _joinFailure(ProviderContainer Function() container) async {
  final deadline = DateTime.now().add(_joinWait);
  while (DateTime.now().isBefore(deadline)) {
    final call = container().read(voiceControllerProvider);
    if (call.state == VoiceSessionState.connected) return null;
    final failure = failedJoin(call);
    if (failure != null) return failure;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  return 'state=${container().read(voiceControllerProvider).state.name} timeout';
}

/// What a call that ended in failure reports, null while it is still going.
@visibleForTesting
String? failedJoin(VoiceState call) => call.state == VoiceSessionState.failed
    ? 'state=failed error=${call.error}'
    : null;

void _logGate(VoiceController voice, ProviderContainer Function() container) {
  var readings = 0;
  var open = 0;
  var strong = 0;
  var peak = -120.0;
  voice.inputGateReadings.listen((reading) {
    readings++;
    if (reading.voice) open++;
    if (reading.strongActive) strong++;
    if (reading.levelDb > peak) peak = reading.levelDb;
  });
  Timer.periodic(const Duration(seconds: 1), (_) {
    final call = container().read(voiceControllerProvider);
    debugPrint(
      'SLIMM_HARNESS call state=${call.state.name} mic=${call.microphoneEnabled} '
      'canPublish=${call.canPublish} people=${call.participants.length} '
      'error=${call.error}',
    );
    debugPrint(
      'SLIMM_HARNESS gate readings=$readings open=$open strong=$strong '
      'peak_db=${peak.toStringAsFixed(1)}',
    );
    readings = open = strong = 0;
    peak = -120.0;
  });
}
