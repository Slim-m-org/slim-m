// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Applies a changed [VoiceProcessing] to a call's live microphone.
library;

import 'audio_device_switching.dart';
import 'mic_port.dart';
import 'mic_release.dart';
import 'voice_log.dart';
import 'voice_processing.dart';

/// libwebrtc fixes echo, gain and suppression when the capture opens, and the
/// fork refuses `setAudioProcessingOptions` at runtime, so a change reopens
/// the capture.
class VoiceProcessingControl {
  VoiceProcessingControl({
    required this.switching,
    required this.mic,
    required this.release,
    required this.micWanted,
    required this.restartCapture,
    required this.reopenMuted,
    this.log,
  });

  final AudioDeviceSwitching switching;
  final MicPort mic;
  final MicRelease release;
  final VoiceLog? log;

  /// Whether the person wants sound going out now.
  final bool Function() micWanted;

  /// Reopens an open capture with the current options; true when it worked.
  final Future<bool> Function(String reason) restartCapture;

  /// Reopens a push-to-talk capture, which stays ready while muted.
  final Future<void> Function() reopenMuted;

  VoiceProcessing get current => switching.processing;

  Future<void> set(VoiceProcessing next, {required bool inCall}) async {
    if (next == switching.processing) return;
    switching.processing = next;
    log?.call('voice-ns: processing ${next.summary}');
    if (!inCall || !mic.hasTrack) return;
    if (micWanted()) {
      await restartCapture('voice processing changed');
      return;
    }
    mic.adoptOptions(switching.captureOptions());
    if (release.keepReady) {
      if (!release.released) await reopenMuted();
      return;
    }
    await release.releaseNow();
  }
}
