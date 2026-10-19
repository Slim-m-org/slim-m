// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'voice_session.dart';

/// What [VoiceSession.join] does besides connecting: the stage marks, and
/// opening the microphone while the connect is still in flight.
extension VoiceSessionJoinWork on VoiceSession {
  /// The default port for a session built with an injected room, which has no
  /// native capture to open ahead of the connect; null keeps the real one.
  MicPort? _standInMic(RoomFactory? injected) =>
      injected == null ? null : LiveKitMicPort(() => _room, preopens: false);

  /// Starts the connect's clock and, when the call will publish a microphone,
  /// opens the capture alongside it with the options the publish will use.
  void _beginJoinWork({required bool microphone}) {
    _joinTimings.mark(JoinStage.connectStarted);
    if (!microphone || _mic is! MicPreopen) return;
    final options = _openCaptureOptions(reopen: _micRelease.released);
    final opening = (_mic as MicPreopen).preopen(options);
    unawaited(opening.then((bool opened) {
      if (opened) _joinTimings.mark(JoinStage.micOpened);
    }));
  }

  /// Marks the first remote audio, once a subscribed track has delivered a packet.
  Future<void> _watchFirstRemoteAudio(lk.RemoteAudioTrack track) async {
    for (var i = 0; i < 100 && _room != null; i++) {
      final stats = await track.getReceiverStats();
      if ((stats?.packetsReceived ?? 0) > 0) {
        _joinTimings.mark(JoinStage.firstRemoteAudio);
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}
