// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The audio counters of a call as plain data, read from a raw stats report.
///
/// A raw report carries fields the livekit wrapper drops (samples received,
/// jitter buffer emitted count, the candidate pair's round trip), so these are
/// parsed here from [StatsEntry] rather than from the wrapper's types.
library;

import 'call_stats.dart' show StatsEntry;

/// The Opus clock when a report names no codec.
const double kDefaultAudioClockRate = 48000;

/// The counters of one remote audio stream that tell concealment from clean audio.
class AudioReceiveSample {
  const AudioReceiveSample({
    this.concealedSamples,
    this.concealmentEvents,
    this.durationSeconds,
    this.totalSamples,
    this.packetsLost,
    this.packetsReceived,
    this.jitterSeconds,
    this.clockRate,
    this.jitterBufferDelay,
    this.jitterBufferEmittedCount,
    this.audioLevel,
    this.rttMs,
  });

  final num? concealedSamples;
  final num? concealmentEvents;

  /// Seconds of audio handed to playout, concealed or not.
  final num? durationSeconds;

  /// The same span counted in samples, when the report has it.
  final num? totalSamples;
  final num? packetsLost;
  final num? packetsReceived;
  final num? jitterSeconds;
  final num? clockRate;

  /// Seconds of buffering summed over every emitted sample.
  final num? jitterBufferDelay;
  final num? jitterBufferEmittedCount;

  /// 0 to 1, linear.
  final num? audioLevel;
  final double? rttMs;

  /// Samples played out so far, whichever of the two counters the report has.
  double? get samples {
    if (totalSamples != null) return totalSamples!.toDouble();
    final seconds = durationSeconds;
    if (seconds == null) return null;
    return (seconds * (clockRate ?? kDefaultAudioClockRate)).toDouble();
  }
}

/// The counters of our own published audio track.
class AudioSendSample {
  const AudioSendSample({
    this.timestampMs,
    this.packetsSent,
    this.bytesSent,
    this.audioLevel,
    this.rttMs,
    this.packetsLost,
    this.jitterSeconds,
  });

  final num? timestampMs;
  final num? packetsSent;
  final num? bytesSent;

  /// What the capture reported, 0 to 1, linear.
  final num? audioLevel;
  final double? rttMs;

  /// Packets the far end reports missing from what we sent.
  final num? packetsLost;
  final num? jitterSeconds;
}

bool _isAudio(StatsEntry e) =>
    (e.text('kind') ?? e.text('mediaType') ?? 'audio') == 'audio';

double? _pairRttMs(List<StatsEntry> entries) {
  final pairs = entries.where((e) => e.type == 'candidate-pair').toList();
  final selectedId = entries
      .where((e) => e.type == 'transport')
      .map((e) => e.text('selectedCandidatePairId'))
      .whereType<String>()
      .firstOrNull;
  final selected = pairs.where((e) => e.id == selectedId).firstOrNull ??
      pairs.where((e) => e.flag('selected') ?? false).firstOrNull;
  final chosen = selected ??
      pairs
          .where((e) =>
              (e.flag('nominated') ?? false) || e.text('state') == 'succeeded')
          .firstOrNull;
  final rtt = chosen?.number('currentRoundTripTime');
  return rtt == null ? null : rtt * 1000;
}

/// The inbound audio stream of one remote track, or null when it has none yet.
AudioReceiveSample? parseAudioReceive(List<StatsEntry> entries) {
  final inbound =
      entries.where((e) => e.type == 'inbound-rtp' && _isAudio(e)).firstOrNull;
  if (inbound == null) return null;
  final codec = entries.where((e) => e.id == inbound.text('codecId'));
  return AudioReceiveSample(
    concealedSamples: inbound.number('concealedSamples'),
    concealmentEvents: inbound.number('concealmentEvents'),
    durationSeconds: inbound.number('totalSamplesDuration'),
    totalSamples: inbound.number('totalSamplesReceived'),
    packetsLost: inbound.number('packetsLost'),
    packetsReceived: inbound.number('packetsReceived'),
    jitterSeconds: inbound.number('jitter'),
    clockRate: codec.firstOrNull?.number('clockRate'),
    jitterBufferDelay: inbound.number('jitterBufferDelay'),
    jitterBufferEmittedCount: inbound.number('jitterBufferEmittedCount'),
    audioLevel: inbound.number('audioLevel'),
    rttMs: _pairRttMs(entries),
  );
}

/// Our outbound audio stream, with the capture level and the far end's view of it.
AudioSendSample? parseAudioSend(List<StatsEntry> entries) {
  final outbound =
      entries.where((e) => e.type == 'outbound-rtp' && _isAudio(e)).firstOrNull;
  if (outbound == null) return null;
  final remote = entries
      .where((e) => e.type == 'remote-inbound-rtp' && _isAudio(e))
      .firstOrNull;
  final source = entries.where((e) => e.type == 'media-source').firstOrNull;
  final remoteRtt = remote?.number('roundTripTime');
  return AudioSendSample(
    timestampMs: outbound.timestampMs,
    packetsSent: outbound.number('packetsSent'),
    bytesSent: outbound.number('bytesSent'),
    audioLevel: source?.number('audioLevel'),
    rttMs: remoteRtt == null ? _pairRttMs(entries) : remoteRtt * 1000,
    packetsLost: remote?.number('packetsLost'),
    jitterSeconds: remote?.number('jitter'),
  );
}

/// Share of the samples played out between two reads that were made up by the
/// decoder, or null when the span is too short to say.
double? concealedShare(AudioReceiveSample before, AudioReceiveSample now) {
  final a = before.samples;
  final b = now.samples;
  if (a == null || b == null) return null;
  final clock = (now.clockRate ?? kDefaultAudioClockRate).toDouble();
  if ((b - a) / clock < 1) return null;
  final concealed =
      (now.concealedSamples ?? 0) - (before.concealedSamples ?? 0);
  return concealed / (b - a);
}
