// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'voice_session.dart';

/// [VoiceSession]'s release of a muted microphone's capture device, a mixin
/// for the reason `voice_session_audio_devices.dart` gives.
mixin VoiceSessionMicRelease {
  lk.Room? get _room;
  MicPort get _mic;
  bool get _micWanted;
  bool _mayPublish = true;
  late final lk.AudioCaptureOptions Function() _plainOpenOptions;
  void _diag(String line, {LogLevel level});
  late final MicRelease _micRelease;
  CaptureNoiseSuppression get _capture;

  void _initMicRelease({
    required Duration grace,
    required bool mobile,
    required lk.AudioCaptureOptions Function() plainOptions,
  }) {
    _plainOpenOptions = plainOptions;
    _micRelease = MicRelease(
      grace: grace,
      mobile: mobile,
      log: _diag,
      release: () async {
        if (_room == null || _micWanted || !_mic.hasTrack) return false;
        await _mic.release();
        return true;
      },
    );
  }

  /// Keeps the capture open while muted, so push to talk keys down instantly.
  Future<void> setKeepMicReady(bool keepReady) async {
    _micRelease.setKeepReady(keepReady);
    if (!keepReady || _room == null || !_mayPublish) return;
    if (_micRelease.released) {
      await _mic.reopenMuted(_plainOpenOptions());
      _micRelease.reopened();
    } else {
      await _primeMutedMic();
    }
  }

  /// A push-to-talk call joins muted with no track, so the first key down
  /// would otherwise open the device and publish; this does that up front.
  /// A listen-only token never publishes, so it opens nothing.
  Future<void> _primeMutedMic() async {
    if (!_mayPublish || !_micRelease.keepReady) return;
    if (_mic.hasTrack || _room == null) return;
    try {
      await _mic.reopenMuted(_plainOpenOptions());
      _micRelease.onMuted();
      _capture.opened(webrtcNoiseSuppression: _capture.webrtcNoiseSuppression);
    } catch (e) {
      _diag('Could not ready the microphone: $e', level: LogLevel.warning);
    }
  }

  /// A phone that goes to the background releases a muted microphone at once.
  void setAppBackgrounded(bool backgrounded) =>
      _micRelease.setBackgrounded(backgrounded);
}
