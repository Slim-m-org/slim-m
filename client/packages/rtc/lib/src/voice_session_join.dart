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
    try {
      if ((await packetsReceived() ?? 0) > 0) {
        onAudio();
        return;
      }
    } on Object catch (error, stack) {
      // Stats can fail while a track is torn down; the loop's bounds end the wait.
      AppLog.swallowed(
          LogTag.voice, 'Could not read receiver stats', error, stack);
    }
    await Future<void>.delayed(every);
  }
}

/// What [VoiceSession.join] does once it is queued: connecting, publishing and the stage marks.
extension VoiceSessionJoinWork on VoiceSession {
  Future<void> _join({
    required String url,
    required String token,
    required bool microphoneEnabled,
    required bool cameraEnabled,
    required bool canPublish,
  }) async {
    if (_disposed) return;
    _mayPublish = canPublish;
    if (_room != null) await leave();
    // Claims the session past the leave above, whose own guard has run by now.
    _generation++;
    // A leave this join superseded never reached idle, which is what ends the old call's health.
    _glitchWatch.finish();

    _lastDisconnect = null;
    _setState(VoiceSessionState.connecting);
    final generation = _generation;
    await _forgetUnpluggedDevices();
    if (_disposed || generation != _generation) return;
    final room = _roomFactory();
    _room = room;
    _listen(room);
    try {
      _joinTimings.mark(JoinStage.connectStarted);
      await room.connect(url, token);
      // A leave or newer join took this room mid-connect and tore it down.
      if (!identical(_room, room)) return;
      _joinTimings.mark(JoinStage.connected);
      // Apart from the connect: a muted preview or a token without SPEAK must not fail the join.
      final micFailed = microphoneEnabled && !await _trySetMicrophone(true);
      if (cameraEnabled) {
        await _trySetCamera(true);
      }
      if (!microphoneEnabled) await _primeMutedMic();
      if (!identical(_room, room)) return;
      _refreshParticipants();
      _setState(VoiceSessionState.connected);
      if (micFailed) _retryMicAfterJoin();
    } catch (e, stack) {
      reportFailure(LogTag.voice, 'join the call', e, stack);
      if (!identical(_room, room)) return;
      _lastError = e;
      _joinTimings.finish();
      await _teardown();
      _setState(VoiceSessionState.failed);
    }
  }

  /// Marks the first remote audio, once a subscribed track has delivered a packet.
  Future<void> _watchFirstRemoteAudio(lk.RemoteAudioTrack track) {
    final room = _room;
    return watchFirstAudio(
      joinOpen: () =>
          room != null && identical(_room, room) && _joinTimings.isOpen,
      packetsReceived: () async =>
          (await track.getReceiverStats())?.packetsReceived,
      onAudio: () => _joinTimings.mark(JoinStage.firstRemoteAudio),
    );
  }
}
