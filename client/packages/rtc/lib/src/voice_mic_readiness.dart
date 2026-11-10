// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether a muted microphone's capture device is held open or let go.
library;

import 'dart:async';

import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_api/api.dart' show LogLevel;

import 'join_timings.dart';
import 'mic_port.dart';
import 'mic_release.dart';

/// What [VoiceMicReadiness] needs from the session that owns it.
class VoiceMicReadinessHost {
  const VoiceMicReadinessHost({
    required this.hasRoom,
    required this.mic,
    required this.micWanted,
    required this.plainOptions,
    required this.joinTimings,
    required this.diag,
  });

  final bool Function() hasRoom;
  final MicPort mic;
  final bool Function() micWanted;

  /// What a muted reopen captures with: the saved choice, no restart on mute.
  final lk.AudioCaptureOptions Function() plainOptions;
  final JoinTimings joinTimings;
  final void Function(String line, {LogLevel level}) diag;
}

/// Releases a muted microphone's capture device after a grace and reopens it,
/// so push to talk keys down instantly and an idle phone does not hold the mic.
class VoiceMicReadiness {
  VoiceMicReadiness(
    this._host, {
    required Duration grace,
    required bool mobile,
  }) {
    release = MicRelease(
      grace: grace,
      mobile: mobile,
      log: _host.diag,
      release: () async {
        if (!_host.hasRoom() || _host.micWanted() || !_host.mic.hasTrack) {
          return false;
        }
        await _host.mic.release();
        return true;
      },
    );
  }

  final VoiceMicReadinessHost _host;
  late final MicRelease release;

  /// Cleared by a listen-only join, which never opens the microphone.
  bool mayPublish = true;

  /// The muted-mic prime in flight, so two callers never publish two tracks.
  Future<void>? _priming;

  /// Keeps the capture open while muted, so push to talk keys down instantly.
  Future<void> setKeepReady(bool keepReady) async {
    release.setKeepReady(keepReady);
    if (!keepReady || !_host.hasRoom() || !mayPublish) return;
    if (release.released) {
      await _host.mic.reopenMuted(_host.plainOptions());
      release.reopened();
    } else {
      await primeMuted();
    }
  }

  /// A push-to-talk call joins muted with no track, so the first key down
  /// would otherwise open the device and publish; this does that up front.
  /// A listen-only token never publishes, so it opens nothing.
  Future<void> primeMuted() {
    final running = _priming;
    if (running != null) return running;
    final next = _primeOnce().whenComplete(() => _priming = null);
    return _priming = next;
  }

  Future<void> _primeOnce() async {
    if (!mayPublish || !release.keepReady) return;
    if (_host.mic.hasTrack || !_host.hasRoom()) return;
    try {
      await _host.mic.reopenMuted(_host.plainOptions());
      _host.joinTimings.mark(JoinStage.micPublished);
      release.onMuted();
    } catch (e) {
      _host.diag('Could not ready the microphone: $e', level: LogLevel.warning);
    }
  }

  /// A phone that goes to the background releases a muted microphone at once.
  void setBackgrounded(bool backgrounded) =>
      release.setBackgrounded(backgrounded);
}
