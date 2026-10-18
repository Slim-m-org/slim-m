// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'voice_session.dart';

/// [VoiceSession]'s release of a muted microphone's capture device, a mixin
/// for the reason `voice_session_audio_devices.dart` gives.
mixin VoiceSessionMicRelease {
  lk.Room? get _room;
  MicPort get _mic;
  bool get _micWanted;
  late final lk.AudioCaptureOptions Function() _plainOpenOptions;
  void _diag(String line, {LogLevel level});
  late final MicRelease _micRelease;

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
    if (!keepReady || !_micRelease.released || _room == null) return;
    await _mic.reopenMuted(_plainOpenOptions());
    _micRelease.reopened();
  }

  /// A phone that goes to the background releases a muted microphone at once.
  void setAppBackgrounded(bool backgrounded) =>
      _micRelease.setBackgrounded(backgrounded);
}
