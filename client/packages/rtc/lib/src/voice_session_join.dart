// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'voice_session.dart';

const _pollEvery = Duration(milliseconds: 50);
const _maxPolls = 100;

/// Polls [packetsReceived] until audio arrives, then calls [onAudio].
///
/// Does nothing unless [joinOpen] says a join is in progress, and stops the
/// moment it is not, so a later subscription in a long call never polls.
@visibleForTesting
Future<void> watchFirstAudio({
  required bool Function() joinOpen,
  required Future<num?> Function() packetsReceived,
  required void Function() onAudio,
  Duration every = _pollEvery,
}) async {
  for (var i = 0; i < _maxPolls && joinOpen(); i++) {
    if ((await packetsReceived() ?? 0) > 0) {
      onAudio();
      return;
    }
    await Future<void>.delayed(every);
  }
}

/// What [VoiceSession.join] does besides connecting: the stage marks.
extension VoiceSessionJoinWork on VoiceSession {
  /// Marks the first remote audio, once a subscribed track has delivered a packet.
  Future<void> _watchFirstRemoteAudio(lk.RemoteAudioTrack track) =>
      watchFirstAudio(
        joinOpen: () => _room != null && _joinTimings.isOpen,
        packetsReceived: () async =>
            (await track.getReceiverStats())?.packetsReceived,
        onAudio: () => _joinTimings.mark(JoinStage.firstRemoteAudio),
      );
}
