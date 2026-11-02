// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'voice_session.dart';

/// Which tracks [VoiceSession.callStats] can read right now.
///
/// Split out for [VoiceSession]'s 500-line ceiling, and private for the same
/// reason as `voice_session_video.dart`.
extension VoiceSessionStats on VoiceSession {
  List<CallStatsTarget> _callStatsTargets() {
    final room = _room;
    if (room == null || _disposed) return const [];
    return [
      ..._localStatsTargets(room.localParticipant),
      for (final peer in room.remoteParticipants.values)
        ..._remoteStatsTargets(peer),
    ];
  }

  void _onStatsSample(VideoStatsSample sample) {
    diagnostics.noteStats(sample);
    _trackSummaries.observe(sample);
  }

  void _recordTrackSummary(String line) {
    diagnostics.noteTrackSummary(line);
    _diag(line);
  }

  /// Keeps the sampler on while we publish video, and closes the summary of any track that is gone.
  void _syncStatsHold() {
    final room = _room;
    if (room == null || _disposed) return;
    final local = _trackKeys(room.localParticipant, local: true);
    callStats.setHeld(local.isNotEmpty);
    local.forEach(_trackSummaries.started);
    final remote = {
      for (final peer in room.remoteParticipants.values)
        ..._trackKeys(peer, local: false),
    };
    _trackSummaries.endExcept({...local, ...remote});
  }

  /// Stops holding the sampler and reports every open summary, for the end of a call.
  void _releaseStats() {
    callStats.setHeld(false);
    _trackSummaries.endAll();
  }

  Set<String> _trackKeys(lk.Participant? who, {required bool local}) => {
        if (who != null)
          for (final pub in who.videoTrackPublications)
            if (_statsSource(pub.source) case final source?)
              statsTrackKey(
                  local: local, identity: who.identity, source: source),
      };

  /// Opens or closes the diagnostics record with the call.
  void _syncCallDiagnostics(VoiceSessionState state) {
    switch (state) {
      case VoiceSessionState.connecting || VoiceSessionState.connected:
        final starting = !diagnostics.active;
        diagnostics.begin();
        if (starting) unawaited(_noteEndpointEffects());
      case VoiceSessionState.idle || VoiceSessionState.failed:
        diagnostics.end();
        _releaseStats();
    }
  }

  /// Reads once per call what Windows does to the microphone on top of our own processing.
  Future<void> _noteEndpointEffects() async {
    try {
      final line = await windowsMicEffectsLine(inputId: audioInputInUse);
      if (line == null || _disposed) return;
      diagnostics.noteEffectsLine(line);
      _diag(line);
    } on Object catch (error, stack) {
      AppLog.swallowed(LogTag.voice, 'No Windows mic effects', error, stack);
    }
  }

  Iterable<CallStatsTarget> _localStatsTargets(
    lk.LocalParticipant? local,
  ) sync* {
    if (local == null) return;
    for (final pub in local.videoTrackPublications) {
      final source = _statsSource(pub.source);
      final track = pub.track;
      final sender = track is lk.LocalVideoTrack ? track.sender : null;
      if (source == null || sender == null) continue;
      yield CallStatsTarget(
        identity: local.identity,
        name: local.name,
        source: source,
        local: true,
        fetch: () async => _entriesOf(await sender.getStats()),
      );
    }
  }

  Iterable<CallStatsTarget> _remoteStatsTargets(
    lk.RemoteParticipant peer,
  ) sync* {
    for (final pub in peer.videoTrackPublications) {
      final source = _statsSource(pub.source);
      final track = pub.track;
      final receiver = track is lk.RemoteVideoTrack ? track.receiver : null;
      if (source == null || receiver == null) continue;
      yield CallStatsTarget(
        identity: peer.identity,
        name: peer.name,
        source: source,
        local: false,
        fetch: () async => _entriesOf(await receiver.getStats()),
      );
    }
  }

  CallStatsSource? _statsSource(lk.TrackSource source) => switch (source) {
        lk.TrackSource.camera => CallStatsSource.camera,
        lk.TrackSource.screenShareVideo => CallStatsSource.screenShare,
        _ => null,
      };

  List<StatsEntry> _entriesOf(List<rtc.StatsReport> reports) => [
        for (final r in reports) StatsEntry.fromReport(r),
      ];
}
