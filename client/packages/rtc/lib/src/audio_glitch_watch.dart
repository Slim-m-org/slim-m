// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Telling a burst of static from the network apart from one of ours.
///
/// A listener hears packet loss as the decoder inventing audio. Logging how
/// much of what each remote person sent was concealed, next to loss and
/// jitter, shows in an exported log whether a burst came from the link.
library;

import 'dart:async';

import 'package:slimm_api/api.dart' show LogLevel;

import 'voice_log.dart';

/// Share of received audio that was concealed, over one interval, worth a line.
const double kConcealedLogShare = 0.05;

/// How often remote audio is sampled.
const Duration kGlitchWatchInterval = Duration(seconds: 5);

/// The counters of one remote audio stream that tell concealment from clean audio.
class AudioReceiveSample {
  const AudioReceiveSample({
    this.concealedSamples,
    this.durationSeconds,
    this.packetsLost,
    this.jitterSeconds,
    this.clockRate,
  });

  final num? concealedSamples;
  final num? durationSeconds;
  final num? packetsLost;
  final num? jitterSeconds;
  final num? clockRate;
}

typedef AudioStatsSource = Future<AudioReceiveSample?> Function();

/// One person's change in concealment between two samples, as a log line, or
/// null when the audio was clean.
String? concealmentLine(
  String who,
  AudioReceiveSample before,
  AudioReceiveSample now,
) {
  final seconds = (now.durationSeconds ?? 0) - (before.durationSeconds ?? 0);
  if (seconds < 1) return null;
  final concealed =
      (now.concealedSamples ?? 0) - (before.concealedSamples ?? 0);
  final clock = (now.clockRate ?? 48000).toDouble();
  final share = concealed / (seconds * clock);
  if (share < kConcealedLogShare) return null;
  final lost = (now.packetsLost ?? 0) - (before.packetsLost ?? 0);
  final jitterMs = ((now.jitterSeconds ?? 0) * 1000).round();
  return 'Audio from $who was ${(share * 100).round()}% concealed over '
      '${seconds.round()} s ($lost packets lost, jitter $jitterMs ms): '
      'the network dropped it, the decoder filled the gap';
}

class AudioGlitchWatch {
  AudioGlitchWatch({
    required this.sources,
    required this.log,
    this.interval = kGlitchWatchInterval,
  });

  /// Every remote person's audio stats, by who it is.
  final Map<String, AudioStatsSource> Function() sources;
  final VoiceLog log;
  final Duration interval;

  Timer? _timer;
  final _previous = <String, AudioReceiveSample>{};

  void start() =>
      _timer ??= Timer.periodic(interval, (_) => unawaited(sample()));

  void stop() {
    _timer?.cancel();
    _timer = null;
    _previous.clear();
  }

  Future<void> sample() async {
    final current = sources();
    _previous.removeWhere((who, _) => !current.containsKey(who));
    for (final entry in current.entries) {
      try {
        final now = await entry.value();
        if (now == null) continue;
        final before = _previous[entry.key];
        _previous[entry.key] = now;
        final line =
            before == null ? null : concealmentLine(entry.key, before, now);
        if (line != null) log(line, level: LogLevel.warning);
      } on Object {
        continue;
      }
    }
  }
}
