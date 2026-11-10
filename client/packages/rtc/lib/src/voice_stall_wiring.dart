// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The stall watchdog's wiring: which remote videos owe frames, and the two
/// recovery steps it can ask for. See [VideoStallWatchdog].
library;

import 'dart:async';

import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_api/api.dart' show LogLevel;

import 'call_stats.dart';
import 'call_stats_sampler.dart';
import 'video_quality.dart';
import 'video_stall_watchdog.dart';
import 'video_subscription_culler.dart';
import 'voice_stats_wiring.dart';

/// What [VoiceStallWiring] needs from the session that owns it.
class VoiceStallWiringHost {
  const VoiceStallWiringHost({
    required this.room,
    required this.disposed,
    required this.reconnecting,
    required this.receiveQuality,
    required this.diag,
  });

  final lk.Room? Function() room;
  final bool Function() disposed;

  /// Frames stand still while the transport repairs itself, and that is not the sender's doing.
  final bool Function() reconnecting;
  final ReceiveVideoQuality Function() receiveQuality;
  final void Function(String line, {LogLevel level}) diag;
}

/// Watches remote video for frames that stopped and walks the recovery steps.
class VoiceStallWiring {
  VoiceStallWiring(
    this._host, {
    required this.sampler,
    required this.culler,
  }) {
    watchdog = VideoStallWatchdog(recover: _recover);
  }

  final VoiceStallWiringHost _host;
  final CallStatsSampler sampler;
  final VideoSubscriptionCuller culler;

  /// See the session's video health; fed by [sampler] while any remote video is subscribed.
  late final VideoStallWatchdog watchdog;
  StreamSubscription<CallStatsSnapshot>? _stats;
  final _activeKeys = <String>{};

  /// Listens to [sampler] only while some remote video is subscribed, so a
  /// call with no video polls nothing.
  void sync() {
    final room = _host.room();
    final wanted = room != null &&
        !_host.disposed() &&
        room.remoteParticipants.values.any(
          (p) => p.videoTrackPublications.any((pub) => pub.subscribed),
        );
    if (wanted && _stats == null) {
      _stats = sampler.snapshots.listen(_onSnapshot);
    } else if (!wanted && _stats != null) {
      // Recovery state stays: a resubscribe step briefly leaves nothing subscribed.
      unawaited(_stats!.cancel());
      _stats = null;
    }
  }

  /// Forgets everything the watch knew; the call is over.
  void stop() {
    unawaited(_stats?.cancel());
    _stats = null;
    _activeKeys.clear();
    watchdog.observe(const []);
  }

  Future<void> dispose() async {
    await _stats?.cancel();
    watchdog.dispose();
  }

  void _onSnapshot(CallStatsSnapshot snapshot) {
    final room = _host.room();
    if (room == null || _host.disposed()) return;
    if (_host.reconnecting()) return;
    final publications = <StallPublication>[
      for (final peer in room.remoteParticipants.values)
        for (final pub in peer.videoTrackPublications)
          if (_key(peer.identity, pub.source) case final key?
              when !culler.blocked.contains(key))
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
              sampledAtMs: _sampledAt(snapshot, peer.identity, pub.source),
            ),
    ];
    _activeKeys.addAll([
      for (final pub in publications)
        if (pub.active) pub.key,
    ]);
    watchdog.observe(
      stallReadings(
        publications,
        interest: culler.interest,
        seenActive: _activeKeys,
      ),
    );
  }

  String? _key(String identity, lk.TrackSource source) => switch (source) {
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

  num? _sampledAt(
    CallStatsSnapshot snapshot,
    String identity,
    lk.TrackSource source,
  ) {
    final streams = _streamsOf(snapshot, identity, source);
    if (streams == null) return null;
    final stamps = [
      for (final s in streams)
        if (s.timestampMs case final t?) t,
    ];
    return stamps.isEmpty ? null : stamps.reduce((a, b) => a > b ? a : b);
  }

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
    final streams = _streamsOf(snapshot, identity, source);
    if (streams == null) return null;
    final values = [
      for (final s in streams)
        if (read(s) case final v?) v,
    ];
    return values.isEmpty ? null : values.reduce((a, b) => a + b);
  }

  Iterable<VideoStreamStats>? _streamsOf(
    CallStatsSnapshot snapshot,
    String identity,
    lk.TrackSource source,
  ) {
    final wanted = callStatsSourceOf(source);
    for (final sample in snapshot) {
      if (sample.local || sample.identity != identity) continue;
      if (sample.source != wanted) continue;
      return sample.streams;
    }
    return null;
  }

  /// One recovery step for the video behind [key]; logs what the stats said.
  void _recover(String key, VideoStallStep step) {
    final room = _host.room();
    if (room == null || _host.disposed()) return;
    for (final peer in room.remoteParticipants.values) {
      for (final pub in peer.videoTrackPublications) {
        if (_key(peer.identity, pub.source) != key) continue;
        _host.diag('Video stalled; trying ${step.name}',
            level: LogLevel.warning);
        unawaited(_runStep(room, key, pub, step));
        return;
      }
    }
  }

  Future<void> _runStep(
    lk.Room room,
    String key,
    lk.RemoteTrackPublication pub,
    VideoStallStep step,
  ) async {
    bool current() => !_host.disposed() && identical(room, _host.room());
    try {
      switch (step) {
        case VideoStallStep.switchLayer:
          // A different layer makes the SFU send a fresh keyframe; best effort, adaptive stream may absorb it.
          final screenShare = pub.source == lk.TrackSource.screenShareVideo;
          final chosen =
              _host.receiveQuality().layerFor(screenShare: screenShare);
          await pub.setVideoQuality(
            chosen == lk.VideoQuality.LOW
                ? lk.VideoQuality.MEDIUM
                : lk.VideoQuality.LOW,
          );
          await Future<void>.delayed(const Duration(seconds: 1));
          if (current()) {
            // Read again: the user may have changed quality during the nudge.
            await pub.setVideoQuality(
              _host.receiveQuality().layerFor(screenShare: screenShare),
            );
          }
        case VideoStallStep.resubscribe:
          await pub.unsubscribe();
          await Future<void>.delayed(const Duration(milliseconds: 500));
          // The culler may have resubscribed already, or stopped wanting it meanwhile.
          if (current() && culler.wants(key)) await pub.subscribe();
      }
    } catch (e) {
      _host.diag(
        'Video stall recovery (${step.name}) failed: $e',
        level: LogLevel.warning,
      );
    }
  }
}
