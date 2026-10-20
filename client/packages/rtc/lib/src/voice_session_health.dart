// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'voice_session.dart';

/// [VoiceSession]'s read of how the call's audio is doing, a mixin for the
/// reason `voice_session_audio_devices.dart` gives.
mixin VoiceSessionHealth {
  lk.Room? get _room;
  void _diag(String line, {LogLevel level});

  /// Per-person quality and the last call's summary; see [VoiceHealth].
  final VoiceHealth health = VoiceHealth();

  late final _glitchWatch = AudioGlitchWatch(
    sources: _remoteVoiceStats,
    nameOf: _nameOf,
    local: _localVoiceStats,
    localIdOf: () => _room?.localParticipant?.identity ?? 'local',
    health: health,
    log: _diag,
  );

  String _nameOf(String identity) {
    final peer = _room?.remoteParticipants[identity];
    return peer == null || peer.name.isEmpty ? identity : peer.name;
  }

  Map<String, AudioStatsSource> _remoteVoiceStats() {
    final out = <String, AudioStatsSource>{};
    final remotes = _room?.remoteParticipants.values.toList() ?? const [];
    for (final p in remotes) {
      for (final pub in p.audioTrackPublications) {
        final track = pub.track;
        if (track is lk.RemoteAudioTrack &&
            pub.source == lk.TrackSource.microphone) {
          out[p.identity] = () async {
            if (pub.muted) return null;
            final reports = await track.receiver?.getStats();
            return reports == null
                ? null
                : parseAudioReceive(_entries(reports));
          };
        }
      }
    }
    return out;
  }

  Future<AudioSendSample?> _localVoiceStats() async {
    final pub = _room?.localParticipant?.audioTrackPublications
        .where((p) => p.source == lk.TrackSource.microphone)
        .firstOrNull;
    final track = pub?.track;
    if (track is! lk.LocalAudioTrack) return null;
    final reports = await track.sender?.getStats();
    return reports == null ? null : parseAudioSend(_entries(reports));
  }

  List<StatsEntry> _entries(List<rtc.StatsReport> reports) =>
      [for (final r in reports) StatsEntry.fromReport(r)];

  /// Cancels the sampling timer without ending the call's history.
  void _stopHealthWatch() => _glitchWatch.stop();

  /// Samples while the call is up; the call's summary is logged when it ends,
  /// not when it is only reconnecting.
  void _syncHealthWatch(VoiceSessionState state) {
    switch (state) {
      case VoiceSessionState.connected:
        _glitchWatch.start();
      case VoiceSessionState.connecting:
        _glitchWatch.stop();
      case VoiceSessionState.idle || VoiceSessionState.failed:
        _glitchWatch.finish();
    }
  }
}

/// Lets tests see the watch behind [VoiceSession.health]; an extension rather
/// than a member so fakes implementing [VoiceSession] need not provide it.
@visibleForTesting
extension VoiceSessionHealthWatchAccess on VoiceSession {
  AudioGlitchWatch get glitchWatch => _glitchWatch;
}
