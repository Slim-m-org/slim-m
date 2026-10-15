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
    final local = room.localParticipant;
    return [
      if (local != null)
        for (final pub in local.videoTrackPublications)
          if (_statsSource(pub.source) case final source?)
            if (pub.track case final lk.LocalVideoTrack track)
              if (track.sender case final sender?)
                CallStatsTarget(
                  identity: local.identity,
                  name: local.name,
                  source: source,
                  local: true,
                  fetch: () async => _entriesOf(await sender.getStats()),
                ),
      for (final peer in room.remoteParticipants.values)
        for (final pub in peer.videoTrackPublications)
          if (_statsSource(pub.source) case final source?)
            if (pub.track case final lk.RemoteVideoTrack track)
              if (track.receiver case final receiver?)
                CallStatsTarget(
                  identity: peer.identity,
                  name: peer.name,
                  source: source,
                  local: false,
                  fetch: () async => _entriesOf(await receiver.getStats()),
                ),
    ];
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
