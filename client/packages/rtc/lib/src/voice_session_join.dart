// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'voice_session.dart';

/// What [VoiceSession.join] does besides connecting: the stage marks.
extension VoiceSessionJoinWork on VoiceSession {
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
