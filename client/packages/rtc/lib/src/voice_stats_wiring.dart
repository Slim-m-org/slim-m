// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which tracks a voice session's [CallStatsSampler] can read right now, and
/// what it does with the samples.
library;

import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_api/api.dart' show AppLog, LogLevel, LogTag;

import 'call_diagnostics.dart';
import 'call_stats.dart';
import 'call_stats_sampler.dart';
import 'endpoint_effects.dart';
import 'track_stats_summary.dart';
import 'voice_models.dart';

/// The stats source a LiveKit track source reads as, or null for one that has no video stats.
CallStatsSource? callStatsSourceOf(lk.TrackSource source) => switch (source) {
      lk.TrackSource.camera => CallStatsSource.camera,
      lk.TrackSource.screenShareVideo => CallStatsSource.screenShare,
      _ => null,
    };

/// What [VoiceStatsWiring] needs from the session that owns it.
class VoiceStatsWiringHost {
  const VoiceStatsWiringHost({
    required this.room,
    required this.disposed,
    required this.audioInputId,
    required this.diag,
  });

  final lk.Room? Function() room;
  final bool Function() disposed;

  /// The microphone id the call is on, for the once-per-call effects read.
  final String? Function() audioInputId;
  final void Function(String line, {LogLevel level}) diag;
}

/// Feeds [sampler] its targets and records what it measures into [diagnostics].
class VoiceStatsWiring {
  VoiceStatsWiring(this._host, this.diagnostics) {
    sampler = CallStatsSampler(
      targets: _targets,
      log: (line) => AppLog.debug(LogTag.voice, line),
      onSample: _onSample,
    );
    _summaries = TrackStatsSummary(onSummary: _recordSummary);
  }

  final VoiceStatsWiringHost _host;
  final CallDiagnostics diagnostics;

  /// Per-track video stats, sampled while somebody watches, listens or we publish video.
  late final CallStatsSampler sampler;
  late final TrackStatsSummary _summaries;

  List<CallStatsTarget> _targets() {
    final room = _host.room();
    if (room == null || _host.disposed()) return const [];
    return [
      ..._localTargets(room.localParticipant),
      for (final peer in room.remoteParticipants.values)
        ..._remoteTargets(peer),
    ];
  }

  void _onSample(VideoStatsSample sample) {
    diagnostics.noteStats(sample);
    _summaries.observe(sample);
  }

  void _recordSummary(String line) {
    diagnostics.noteTrackSummary(line);
    _host.diag(line);
  }

  /// Keeps the sampler on while we publish video, and closes the summary of any track that is gone.
  void syncHold() {
    final room = _host.room();
    if (room == null || _host.disposed()) return;
    final local = _trackKeys(room.localParticipant, local: true);
    sampler.setHeld(local.isNotEmpty);
    local.forEach(_summaries.started);
    final remote = {
      for (final peer in room.remoteParticipants.values)
        ..._trackKeys(peer, local: false),
    };
    _summaries.endExcept({...local, ...remote});
  }

  /// Stops holding the sampler and reports every open summary, for the end of a call.
  void release() {
    sampler.setHeld(false);
    _summaries.endAll();
  }

  Set<String> _trackKeys(lk.Participant? who, {required bool local}) => {
        if (who != null)
          for (final pub in who.videoTrackPublications)
            if (callStatsSourceOf(pub.source) case final source?)
              statsTrackKey(
                  local: local, identity: who.identity, source: source),
      };

  /// Opens or closes the diagnostics record with the call.
  void syncDiagnostics(VoiceSessionState state) {
    switch (state) {
      case VoiceSessionState.connecting || VoiceSessionState.connected:
        final starting = !diagnostics.active;
        diagnostics.begin();
        if (starting) unawaited(_noteEndpointEffects());
      case VoiceSessionState.idle || VoiceSessionState.failed:
        diagnostics.end();
        release();
    }
  }

  /// Reads once per call what Windows does to the microphone on top of our own processing.
  Future<void> _noteEndpointEffects() async {
    try {
      final line = await windowsMicEffectsLine(inputId: _host.audioInputId());
      if (line == null || _host.disposed()) return;
      diagnostics.noteEffectsLine(line);
      _host.diag(line);
    } on Object catch (error, stack) {
      AppLog.swallowed(LogTag.voice, 'No Windows mic effects', error, stack);
    }
  }

  Iterable<CallStatsTarget> _localTargets(lk.LocalParticipant? local) sync* {
    if (local == null) return;
    for (final pub in local.videoTrackPublications) {
      final source = callStatsSourceOf(pub.source);
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

  Iterable<CallStatsTarget> _remoteTargets(lk.RemoteParticipant peer) sync* {
    for (final pub in peer.videoTrackPublications) {
      final source = callStatsSourceOf(pub.source);
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

  List<StatsEntry> _entriesOf(List<rtc.StatsReport> reports) => [
        for (final r in reports) StatsEntry.fromReport(r),
      ];
}
