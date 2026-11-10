// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A voice session's read of how the call's audio is doing.
library;

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_api/api.dart' show LogLevel;

import 'audio_glitch_watch.dart';
import 'audio_stats.dart';
import 'call_diagnostics.dart';
import 'call_stats.dart';
import 'voice_health.dart';
import 'voice_models.dart';

/// What [VoiceHealthWatch] needs from the session that owns it.
class VoiceHealthWatchHost {
  const VoiceHealthWatchHost({required this.room, required this.diag});

  final lk.Room? Function() room;
  final void Function(String line, {LogLevel level}) diag;
}

/// Samples the call's audio stats into [health] and [diagnostics].
class VoiceHealthWatch {
  VoiceHealthWatch(this._host);

  final VoiceHealthWatchHost _host;

  /// Per-person quality and the last call's summary; see [VoiceHealth].
  final VoiceHealth health = VoiceHealth();

  /// What a call report needs, kept apart from the debug log; see [CallDiagnostics].
  final CallDiagnostics diagnostics = CallDiagnostics();

  late final AudioGlitchWatch glitchWatch = AudioGlitchWatch(
    sources: _remoteVoiceStats,
    nameOf: _nameOf,
    local: _localVoiceStats,
    shareSources: _remoteShareStats,
    localIdOf: () => _host.room()?.localParticipant?.identity ?? 'local',
    health: health,
    log: _log,
  );

  final _mediaSource = MediaSourceNote();

  void _log(String line, {LogLevel level = LogLevel.info}) {
    diagnostics.noteHealthLine(line);
    _host.diag(line, level: level);
  }

  String _nameOf(String identity) {
    final peer = _host.room()?.remoteParticipants[identity];
    return peer == null || peer.name.isEmpty ? identity : peer.name;
  }

  Map<String, AudioStatsSource> _remoteVoiceStats() =>
      _remoteAudioStats(lk.TrackSource.microphone);

  Map<String, AudioStatsSource> _remoteShareStats() =>
      _remoteAudioStats(lk.TrackSource.screenShareAudio);

  Map<String, AudioStatsSource> _remoteAudioStats(lk.TrackSource source) {
    final out = <String, AudioStatsSource>{};
    final remotes =
        _host.room()?.remoteParticipants.values.toList() ?? const [];
    for (final p in remotes) {
      for (final pub in p.audioTrackPublications) {
        final track = pub.track;
        if (track is lk.RemoteAudioTrack && pub.source == source) {
          out[p.identity] = _receiveStats(pub, track);
        }
      }
    }
    return out;
  }

  AudioStatsSource _receiveStats(
    lk.TrackPublication pub,
    lk.RemoteAudioTrack track,
  ) =>
      () async {
        if (pub.muted) return null;
        final reports = await track.receiver?.getStats();
        return reports == null ? null : parseAudioReceive(_entries(reports));
      };

  Future<AudioSendSample?> _localVoiceStats() async {
    final pub = _host
        .room()
        ?.localParticipant
        ?.audioTrackPublications
        .where((p) => p.source == lk.TrackSource.microphone)
        .firstOrNull;
    final track = pub?.track;
    if (track is! lk.LocalAudioTrack) return null;
    final reports = await track.sender?.getStats();
    if (reports == null) return null;
    final entries = _entries(reports);
    diagnostics.noteTransport(parseTransportStats(entries));
    _mediaSource.note(entries, _host.diag);
    return parseAudioSend(entries);
  }

  List<StatsEntry> _entries(List<rtc.StatsReport> reports) =>
      [for (final r in reports) StatsEntry.fromReport(r)];

  /// Cancels the sampling timer without ending the call's history.
  void stop() => glitchWatch.stop();

  /// Samples while the call is up; the call's summary is logged when it ends,
  /// not when it is only reconnecting.
  void sync(VoiceSessionState state) {
    switch (state) {
      case VoiceSessionState.connected:
        glitchWatch.start();
      case VoiceSessionState.connecting:
        glitchWatch.stop();
      case VoiceSessionState.idle || VoiceSessionState.failed:
        glitchWatch.finish();
    }
  }
}
