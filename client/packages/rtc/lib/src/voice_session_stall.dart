// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'voice_session.dart';

/// The stall watchdog's wiring: which remote videos owe frames, and the two
/// recovery steps it can ask for. See [VideoStallWatchdog].
extension VoiceSessionStall on VoiceSession {
  /// Listens to [callStats] only while some remote video is subscribed, so a
  /// call with no video polls nothing.
  void _syncStallWatch() {
    final room = _room;
    final wanted = room != null &&
        !_disposed &&
        room.remoteParticipants.values.any(
          (p) => p.videoTrackPublications.any((pub) => pub.subscribed),
        );
    if (wanted && _stallStats == null) {
      _stallStats = callStats.snapshots.listen(_onStallSnapshot);
    } else if (!wanted && _stallStats != null) {
      // Recovery state stays: a resubscribe step briefly leaves nothing subscribed.
      unawaited(_stallStats!.cancel());
      _stallStats = null;
    }
  }

  /// Forgets everything the watch knew; the call is over.
  void _stopStallWatch() {
    unawaited(_stallStats?.cancel());
    _stallStats = null;
    _activeVideoKeys.clear();
    _stallWatchdog.observe(const []);
  }

  void _onStallSnapshot(CallStatsSnapshot snapshot) {
    final room = _room;
    if (room == null || _disposed) return;
    final publications = <StallPublication>[
      for (final peer in room.remoteParticipants.values)
        for (final pub in peer.videoTrackPublications)
          if (_stallKey(peer.identity, pub.source) case final key?)
            (
              key: key,
              subscribed: pub.subscribed,
              muted: pub.muted,
              active: pub.streamState == lk.StreamState.active,
              framesDecoded:
                  _framesDecoded(snapshot, peer.identity, pub.source),
              bytesReceived:
                  _bytesReceived(snapshot, peer.identity, pub.source),
              screenShare: pub.source == lk.TrackSource.screenShareVideo,
            ),
    ];
    _activeVideoKeys.addAll([
      for (final pub in publications)
        if (pub.active) pub.key,
    ]);
    _stallWatchdog.observe(
      stallReadings(
        publications,
        interest: _videoCuller.interest,
        seenActive: _activeVideoKeys,
      ),
    );
  }

  String? _stallKey(String identity, lk.TrackSource source) => switch (source) {
        lk.TrackSource.camera =>
          videoSubscriptionKey(identity: identity, screenShare: false),
        lk.TrackSource.screenShareVideo =>
          videoSubscriptionKey(identity: identity, screenShare: true),
        _ => null,
      };

  int? _framesDecoded(
    CallStatsSnapshot snapshot,
    String identity,
    lk.TrackSource source,
  ) =>
      _sumOf(snapshot, identity, source, (s) => s.framesDecoded)?.toInt();

  num? _bytesReceived(
    CallStatsSnapshot snapshot,
    String identity,
    lk.TrackSource source,
  ) =>
      _sumOf(snapshot, identity, source, (s) => s.bytes);

  num? _sumOf(
    CallStatsSnapshot snapshot,
    String identity,
    lk.TrackSource source,
    num? Function(VideoStreamStats) read,
  ) {
    final wanted = _statsSource(source);
    for (final sample in snapshot) {
      if (sample.local || sample.identity != identity) continue;
      if (sample.source != wanted) continue;
      final values = [
        for (final s in sample.streams)
          if (read(s) case final v?) v,
      ];
      return values.isEmpty ? null : values.reduce((a, b) => a + b);
    }
    return null;
  }

  /// One recovery step for the video behind [key]; logs what the stats said.
  void _recoverStalledVideo(String key, VideoStallStep step) {
    final room = _room;
    if (room == null || _disposed) return;
    for (final peer in room.remoteParticipants.values) {
      for (final pub in peer.videoTrackPublications) {
        if (_stallKey(peer.identity, pub.source) != key) continue;
        debugPrint('video stall: $key, trying ${step.name}');
        unawaited(_runStallStep(room, key, pub, step));
        return;
      }
    }
  }

  Future<void> _runStallStep(
    lk.Room room,
    String key,
    lk.RemoteTrackPublication pub,
    VideoStallStep step,
  ) async {
    try {
      switch (step) {
        case VideoStallStep.switchLayer:
          // A different layer makes the SFU send a fresh keyframe; best effort, adaptive stream may absorb it.
          final screenShare = pub.source == lk.TrackSource.screenShareVideo;
          final chosen = _receiveQuality.layerFor(screenShare: screenShare);
          await pub.setVideoQuality(
            chosen == lk.VideoQuality.LOW
                ? lk.VideoQuality.MEDIUM
                : lk.VideoQuality.LOW,
          );
          await Future<void>.delayed(const Duration(seconds: 1));
          if (!_disposed && identical(room, _room)) {
            // Read again: the user may have changed quality during the nudge.
            await pub.setVideoQuality(
              _receiveQuality.layerFor(screenShare: screenShare),
            );
          }
        case VideoStallStep.resubscribe:
          await pub.unsubscribe();
          await Future<void>.delayed(const Duration(milliseconds: 500));
          final interest = _videoCuller.interest;
          // The culler may have resubscribed already, or stopped wanting it meanwhile.
          if (!_disposed &&
              identical(room, _room) &&
              (interest == null || interest.contains(key))) {
            await pub.subscribe();
          }
      }
    } catch (e) {
      debugPrint('video stall: ${step.name} failed: $e');
    }
  }
}
