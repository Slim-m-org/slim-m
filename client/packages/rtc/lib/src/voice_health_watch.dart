// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A voice session's read of how the call's audio is doing.
library;

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_api/api.dart' show LogLevel;

import 'audio_glitch_watch.dart';
import 'audio_stats.dart';
import 'call_diagnostics.dart';
import 'call_link.dart';
import 'call_stats.dart';
import 'join_audio_probe.dart';
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
    note: diagnostics.noteHealthLine,
  );

  final _mediaSource = MediaSourceNote();
  final _pulse = SignalPulse();

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

  /// Each remote voice by name, readable or not, for [JoinAudioProbe].
  Map<String, RemoteVoiceProbe> remoteVoiceProbes() {
    final out = <String, RemoteVoiceProbe>{};
    final remotes =
        _host.room()?.remoteParticipants.values.toList() ?? const [];
    for (final p in remotes) {
      for (final pub in p.audioTrackPublications) {
        if (pub.source != lk.TrackSource.microphone) continue;
        final track = pub.track;
        out[_nameOf(p.identity)] = track is lk.RemoteAudioTrack
            ? (
                blocked: pub.muted ? 'muted by them' : null,
                playing: pub.enabled && track.mediaStreamTrack.enabled,
                stats: _receiveStats(pub, track),
              )
            : (blocked: 'not subscribed', playing: false, stats: _noStats);
      }
    }
    return out;
  }

  static Future<AudioReceiveSample?> _noStats() async => null;

  /// What the microphone sends, for [JoinAudioProbe].
  Future<AudioSendSample?> localVoiceStats() => _localVoiceStats();

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
    final room = _host.room();
    final pub = room?.localParticipant?.audioTrackPublications
        .where((p) => p.source == lk.TrackSource.microphone)
        .firstOrNull;
    final track = pub?.track;
    final reports =
        track is lk.LocalAudioTrack ? await track.sender?.getStats() : null;
    if (reports == null) {
      _noteLink(room, null);
      return null;
    }
    final entries = _entries(reports);
    final transport = parseTransportStats(entries);
    diagnostics.noteTransport(transport);
    _noteLink(room, transport);
    _mediaSource.note(entries, _host.diag);
    return parseAudioSend(entries);
  }

  /// Keeps the last media reading when [transport] is null, so a muted moment does not blank it.
  void _noteLink(lk.Room? room, TransportStats? transport) {
    if (room == null) return;
    final counters = signalCounters(room);
    final signal = _pulse.observe(
      pings: counters.pings,
      rttMs: counters.rttMs,
    );
    final before = health.link.value;
    health.link.value = CallLink(
      mediaRttMs: transport?.rttMs?.round() ?? before?.mediaRttMs,
      media: mediaRouteOf(transport) ?? before?.media,
      signalRttMs: signal.rttMs,
      signalSilence: signal.silence,
    );
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
        _pulse.reset();
        glitchWatch.finish();
    }
  }
}
