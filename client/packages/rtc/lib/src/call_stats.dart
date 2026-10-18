// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Turning a WebRTC stats report into the few numbers worth looking at.
///
/// Plain data in and out, so a test can feed it a fake report and nothing here
/// depends on a call being up.
library;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

/// Which video track a sample describes.
enum CallStatsSource { camera, screenShare }

/// One entry of a `getStats` report, detached from the plugin type.
class StatsEntry {
  const StatsEntry({
    required this.type,
    required this.id,
    this.timestampMs = 0,
    this.values = const {},
  });

  /// A browser reports `timestamp` in milliseconds; every native plugin
  /// (desktop, Android, iOS) reports microseconds, so [web] picks the unit.
  factory StatsEntry.fromReport(rtc.StatsReport report, {bool web = kIsWeb}) =>
      StatsEntry(
        type: report.type,
        id: report.id,
        timestampMs: web ? report.timestamp : report.timestamp / 1000,
        values: {for (final e in report.values.entries) '${e.key}': e.value},
      );

  final String type;
  final String id;
  final num timestampMs;
  final Map<String, Object?> values;

  num? number(String key) {
    final v = values[key];
    if (v is num) return v;
    return v is String ? num.tryParse(v) : null;
  }

  String? text(String key) {
    final v = values[key];
    return v is String && v.isNotEmpty ? v : null;
  }

  bool? flag(String key) {
    final v = values[key];
    if (v is bool) return v;
    return v is String ? bool.tryParse(v) : null;
  }
}

/// One RTP stream: a simulcast layer when sending, the received video when
/// receiving.
class VideoStreamStats {
  const VideoStreamStats({
    required this.id,
    this.rid,
    this.width,
    this.height,
    this.fps,
    this.bitrateBps,
    this.targetBitrateBps,
    this.codec,
    this.implementation,
    this.powerEfficient,
    this.limitationReason,
    this.limitationResolutionChanges,
    this.active,
    this.framesDropped,
    this.framesDecoded,
    this.freezeCount,
    this.freezeSeconds,
    this.pauseCount,
    this.keyFrames,
    this.pliCount,
    this.firCount,
    this.nackCount,
    this.packetsLost,
    this.jitterMs,
    this.jitterBufferMs,
    this.bytes,
    this.timestampMs,
  });

  final String id;
  final String? rid;
  final int? width;
  final int? height;
  final double? fps;

  /// Measured from the byte counter against the previous sample; null on the
  /// first one.
  final double? bitrateBps;
  final double? targetBitrateBps;

  /// For example `VP8`.
  final String? codec;

  /// The encoder or decoder, for example `libvpx`.
  final String? implementation;
  final bool? powerEfficient;

  /// Sending only: `none`, `bandwidth`, `cpu` or `other`.
  final String? limitationReason;
  final int? limitationResolutionChanges;
  final bool? active;

  /// Receiving only.
  final int? framesDropped;

  /// Frames this receiver has decoded so far; the stall watchdog's clock.
  final int? framesDecoded;
  final int? freezeCount;
  final double? freezeSeconds;
  final int? pauseCount;
  final int? packetsLost;
  final double? jitterMs;
  final double? jitterBufferMs;

  final int? keyFrames;
  final int? pliCount;
  final int? firCount;
  final int? nackCount;

  /// Counter behind [bitrateBps], kept so the next sample can diff against it.
  final num? bytes;
  final num? timestampMs;
}

/// The network path the stream rides.
class TransportStats {
  const TransportStats({
    this.rttMs,
    this.availableOutgoingBps,
    this.localType,
    this.remoteType,
    this.protocol,
  });

  final double? rttMs;
  final double? availableOutgoingBps;

  /// `host`, `srflx`, `prflx` or `relay`.
  final String? localType;
  final String? remoteType;

  /// `udp` or `tcp`.
  final String? protocol;

  bool get relayed => localType == 'relay' || remoteType == 'relay';
}

/// Everything sampled from one video track at one moment.
class VideoStatsSample {
  const VideoStatsSample({
    required this.identity,
    required this.name,
    required this.source,
    required this.local,
    required this.streams,
    this.transport,
  });

  final String identity;
  final String name;
  final CallStatsSource source;

  /// True when this is our own published track.
  final bool local;
  final List<VideoStreamStats> streams;
  final TransportStats? transport;

  String get key => '${local ? 'out' : 'in'}/$identity/${source.name}';
}

/// Parses [entries] from one sender or receiver into a sample.
///
/// [previous] is the last sample of the same track, used to turn the byte
/// counters into a bitrate.
VideoStatsSample parseVideoStats(
  List<StatsEntry> entries, {
  required String identity,
  required String name,
  required CallStatsSource source,
  required bool local,
  VideoStatsSample? previous,
}) {
  final byId = {for (final e in entries) e.id: e};
  final wanted = local ? 'outbound-rtp' : 'inbound-rtp';
  final previousById = {
    for (final s in previous?.streams ?? const <VideoStreamStats>[]) s.id: s
  };
  final streams = <VideoStreamStats>[
    for (final e in entries)
      if (e.type == wanted && _isVideo(e))
        _parseStream(e, byId, previousById[e.id], local: local),
  ]..sort((a, b) => (a.width ?? 0).compareTo(b.width ?? 0));
  return VideoStatsSample(
    identity: identity,
    name: name,
    source: source,
    local: local,
    streams: streams,
    transport: _parseTransport(entries, byId),
  );
}

bool _isVideo(StatsEntry e) =>
    (e.text('kind') ?? e.text('mediaType') ?? 'video') == 'video';

VideoStreamStats _parseStream(
  StatsEntry e,
  Map<String, StatsEntry> byId,
  VideoStreamStats? previous, {
  required bool local,
}) {
  final bytes = e.number(local ? 'bytesSent' : 'bytesReceived');
  final jitterBufferEmitted = e.number('jitterBufferEmittedCount');
  final jitterBufferDelay = e.number('jitterBufferDelay');
  final codec = byId[e.text('codecId')]?.text('mimeType');
  return VideoStreamStats(
    id: e.id,
    rid: e.text('rid'),
    width: e.number('frameWidth')?.toInt(),
    height: e.number('frameHeight')?.toInt(),
    fps: e.number('framesPerSecond')?.toDouble(),
    bitrateBps: _bitrate(bytes, e.timestampMs, previous),
    targetBitrateBps: e.number('targetBitrate')?.toDouble(),
    codec: codec?.replaceFirst('video/', ''),
    implementation:
        e.text(local ? 'encoderImplementation' : 'decoderImplementation'),
    powerEfficient: e.flag(
      local ? 'powerEfficientEncoder' : 'powerEfficientDecoder',
    ),
    limitationReason: e.text('qualityLimitationReason'),
    limitationResolutionChanges:
        e.number('qualityLimitationResolutionChanges')?.toInt(),
    active: e.flag('active'),
    framesDropped: e.number('framesDropped')?.toInt(),
    framesDecoded: local ? null : e.number('framesDecoded')?.toInt(),
    freezeCount: e.number('freezeCount')?.toInt(),
    freezeSeconds: e.number('totalFreezesDuration')?.toDouble(),
    pauseCount: e.number('pauseCount')?.toInt(),
    keyFrames:
        e.number(local ? 'keyFramesEncoded' : 'keyFramesDecoded')?.toInt(),
    pliCount: e.number('pliCount')?.toInt(),
    firCount: e.number('firCount')?.toInt(),
    nackCount: e.number('nackCount')?.toInt(),
    packetsLost: e.number('packetsLost')?.toInt(),
    jitterMs: e.number('jitter') == null ? null : e.number('jitter')! * 1000,
    jitterBufferMs: jitterBufferDelay == null ||
            jitterBufferEmitted == null ||
            jitterBufferEmitted == 0
        ? null
        : jitterBufferDelay / jitterBufferEmitted * 1000,
    bytes: bytes,
    timestampMs: e.timestampMs,
  );
}

double? _bitrate(num? bytes, num timestampMs, VideoStreamStats? previous) {
  final lastBytes = previous?.bytes;
  final lastAt = previous?.timestampMs;
  if (bytes == null || lastBytes == null || lastAt == null) return null;
  final seconds = (timestampMs - lastAt) / 1000;
  if (seconds <= 0 || bytes < lastBytes) return null;
  return (bytes - lastBytes) * 8 / seconds;
}

TransportStats? _parseTransport(
  List<StatsEntry> entries,
  Map<String, StatsEntry> byId,
) {
  final pair = entries
      .where((e) => e.type == 'candidate-pair')
      .where((e) =>
          (e.flag('nominated') ?? false) || e.text('state') == 'succeeded')
      .firstOrNull;
  if (pair == null) return null;
  final rtt = pair.number('currentRoundTripTime');
  return TransportStats(
    rttMs: rtt == null ? null : rtt * 1000,
    availableOutgoingBps: pair.number('availableOutgoingBitrate')?.toDouble(),
    localType: byId[pair.text('localCandidateId')]?.text('candidateType'),
    remoteType: byId[pair.text('remoteCandidateId')]?.text('candidateType'),
    protocol: byId[pair.text('localCandidateId')]?.text('protocol'),
  );
}

/// One line per sample, for the console.
String statsLogLine(VideoStatsSample s) {
  final who = '${s.local ? 'out' : 'in'} ${s.source.name} ${s.identity}';
  final layers = [for (final st in s.streams) _streamLogPart(st)];
  final t = s.transport;
  final path = t == null
      ? ''
      : ' | rtt=${_fixed(t.rttMs, 0)}ms ${t.localType ?? '?'}/${t.protocol ?? '?'}';
  return '[call-stats] $who ${layers.join(' ; ')}$path';
}

String _streamLogPart(VideoStreamStats st) => [
      if (st.rid != null) st.rid!,
      '${st.width ?? '?'}x${st.height ?? '?'}@${_fixed(st.fps, 0)}',
      '${_mbps(st.bitrateBps)}Mbps',
      if (st.targetBitrateBps != null) 'target=${_mbps(st.targetBitrateBps)}',
      if (st.codec != null) st.codec!,
      if (st.implementation != null) st.implementation!,
      if (st.limitationReason != null) 'limit=${st.limitationReason}',
      if (st.freezeCount != null) 'freezes=${st.freezeCount}',
      if (st.framesDropped != null) 'dropped=${st.framesDropped}',
    ].join(' ');

String _fixed(num? v, int digits) =>
    v == null ? '?' : v.toStringAsFixed(digits);

String _mbps(double? bps) => bps == null ? '?' : (bps / 1e6).toStringAsFixed(2);
