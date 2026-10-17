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
