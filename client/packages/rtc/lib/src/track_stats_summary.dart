// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Rolling every sample of one camera or screen share into the single line
/// worth reading once it ends.
///
/// The per-sample lines say what a moment looked like; this says what the
/// whole share was, which is what a bug report about "it got blurry" needs.
library;

import 'call_stats.dart';

/// A gap longer than this between two samples is not credited to either
/// side's limitation reason: the sampler was not running.
const Duration kSummaryMaxGap = Duration(seconds: 20);

int _rank(String reason) => switch (reason) {
      'cpu' => 3,
      'bandwidth' => 2,
      'none' => 0,
      _ => 1,
    };

class _Layer {
  double fpsSum = 0;
  int fpsCount = 0;
  double bitrateSum = 0;
  int bitrateCount = 0;
  int? width;
  int? height;
}

class _Run {
  _Run(this.key, this.startedAt);

  final String key;
  final DateTime startedAt;
  String? identity;
  bool local = false;
  CallStatsSource? source;
  DateTime? firstFrameAt;
  DateTime? lastAt;
  int samples = 0;
  final secondsByReason = <String, double>{};
  final layers = <String, _Layer>{};
  String? encoder;
  String? codec;
  int keyframeRequests = 0;
  int freezes = 0;
  double freezeSeconds = 0;
}

/// Collects samples per track and reports one summary line when it ends.
class TrackStatsSummary {
  TrackStatsSummary({required this.onSummary, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final void Function(String line) onSummary;
  final DateTime Function() _clock;
  final _runs = <String, _Run>{};

  /// Marks the moment a track appeared, so time to first frame counts from it
  /// rather than from the first sample.
  void started(String key, {DateTime? at}) =>
      _runs.putIfAbsent(key, () => _Run(key, at ?? _clock()));

  void observe(VideoStatsSample sample, {DateTime? at}) {
    final now = at ?? _clock();
    final run = _runs.putIfAbsent(sample.key, () => _Run(sample.key, now))
      ..identity = sample.identity
      ..local = sample.local
      ..source = sample.source
      ..samples += 1;
    _credit(run, sample, now);
    if (run.firstFrameAt == null && sample.streams.any(_hasFrames)) {
      run.firstFrameAt = now;
    }
    _fold(run, sample);
    run.lastAt = now;
  }

  /// Reports and forgets every track whose key is not in [live].
  void endExcept(Set<String> live) {
    for (final key in _runs.keys.where((k) => !live.contains(k)).toList()) {
      _finish(key);
    }
  }

  void endAll() => endExcept(const {});

  void _credit(_Run run, VideoStatsSample sample, DateTime now) {
    final last = run.lastAt;
    if (last == null) return;
    final gap = now.difference(last);
    if (gap > kSummaryMaxGap || gap <= Duration.zero) return;
    final reason = _reasonOf(sample);
    if (reason == null) return;
    run.secondsByReason.update(
      reason,
      (s) => s + gap.inMilliseconds / 1000,
      ifAbsent: () => gap.inMilliseconds / 1000,
    );
  }

  void _fold(_Run run, VideoStatsSample sample) {
    var keyframes = 0;
    var freezes = 0;
    var freezeSeconds = 0.0;
    for (final s in sample.streams) {
      run.encoder = s.implementation ?? run.encoder;
      run.codec = s.codec ?? run.codec;
      keyframes += s.pliCount ?? 0;
      freezes += s.freezeCount ?? 0;
      freezeSeconds += s.freezeSeconds ?? 0;
      if (s.active == false) continue;
      final layer = run.layers.putIfAbsent(s.rid ?? '', _Layer.new);
      layer.width = s.width ?? layer.width;
      layer.height = s.height ?? layer.height;
      if (s.fps case final fps?) {
        layer.fpsSum += fps;
        layer.fpsCount += 1;
      }
      if (s.bitrateBps case final bps?) {
        layer.bitrateSum += bps;
        layer.bitrateCount += 1;
      }
    }
    if (keyframes > run.keyframeRequests) run.keyframeRequests = keyframes;
    if (freezes > run.freezes) run.freezes = freezes;
    if (freezeSeconds > run.freezeSeconds) run.freezeSeconds = freezeSeconds;
  }

  void _finish(String key) {
    final run = _runs.remove(key);
    if (run == null || run.samples == 0) return;
    onSummary(_line(run));
  }
}

bool _hasFrames(VideoStreamStats s) =>
    s.width != null && s.height != null && (s.fps ?? 0) > 0;

/// The one reason that describes a sample: the worst any layer reported.
String? _reasonOf(VideoStatsSample sample) {
  final reasons = [
    for (final s in sample.streams)
      if (s.limitationReason case final r?) r,
  ];
  if (reasons.isEmpty) return null;
  return reasons.reduce((a, b) => _rank(b) > _rank(a) ? b : a);
}

String _line(_Run run) {
  final who = '${run.local ? 'out' : 'in'} ${run.source?.name} ${run.identity}';
  final span = run.lastAt!.difference(run.startedAt).inSeconds;
  final parts = [
    'over ${span}s',
    if (run.secondsByReason.isNotEmpty) 'limit ${_reasons(run)}',
    if (run.layers.isNotEmpty) run.layers.entries.map(_layer).join(' ; '),
    if (run.encoder != null || run.codec != null)
      [if (run.encoder != null) run.encoder!, if (run.codec != null) run.codec!]
          .join(' '),
    if (run.keyframeRequests > 0) 'keyframe requests=${run.keyframeRequests}',
    if (!run.local)
      'freezes=${run.freezes} (${run.freezeSeconds.toStringAsFixed(1)}s)',
    _firstFrame(run),
  ];
  return '[call-stats] summary $who ${parts.join(' | ')}';
}

String _reasons(_Run run) => run.secondsByReason.entries
    .map((e) => '${e.key}=${e.value.round()}s')
    .join(' ');

String _layer(MapEntry<String, _Layer> e) {
  final l = e.value;
  final size =
      l.width == null || l.height == null ? '?' : '${l.width}x${l.height}';
  final fps =
      l.fpsCount == 0 ? '?' : (l.fpsSum / l.fpsCount).toStringAsFixed(1);
  final mbps = l.bitrateCount == 0
      ? '?'
      : (l.bitrateSum / l.bitrateCount / 1e6).toStringAsFixed(2);
  return '${e.key.isEmpty ? '' : '${e.key} '}$size mean ${fps}fps ${mbps}Mbps';
}

String _firstFrame(_Run run) {
  final at = run.firstFrameAt;
  if (at == null) return 'no frame seen';
  final seconds = at.difference(run.startedAt).inMilliseconds / 1000;
  return 'first frame ${seconds.toStringAsFixed(1)}s';
}
