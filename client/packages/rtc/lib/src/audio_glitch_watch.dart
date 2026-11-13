// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Telling a burst of static from the network apart from one of ours.
///
/// A listener hears packet loss as the decoder inventing audio. Logging how
/// much of what each remote person sent was concealed, next to loss and
/// jitter, shows in an exported log whether a burst came from the link.
library;

import 'dart:async';

import 'package:slimm_api/api.dart' show AppLog, LogLevel, LogTag;

import 'audio_stats.dart';
import 'voice_health.dart';
import 'voice_log.dart';

export 'audio_stats.dart' show AudioReceiveSample, AudioSendSample;

/// Share of received audio that was concealed, over one interval, worth a line.
const double kConcealedLogShare = kPoorConcealmentShare;

/// How often remote audio is sampled.
const Duration kGlitchWatchInterval = Duration(seconds: 5);

/// Appended to a person's identity to key their screen-share audio apart from their voice.
const String kShareKeySuffix = '#share';

/// Share audio is read on every Nth sample: it is a second stream per person, not worth the voice cadence.
const int kShareSampleEvery = 4;

typedef AudioStatsSource = Future<AudioReceiveSample?> Function();
typedef AudioSendSource = Future<AudioSendSample?> Function();

/// One person's change in concealment between two samples, as a log line, or
/// null when the audio was clean.
String? concealmentLine(
  String who,
  AudioReceiveSample before,
  AudioReceiveSample now,
) {
  final share = concealedShare(before, now);
  if (share == null || share < kConcealedLogShare) return null;
  final seconds = (now.samples! - before.samples!) /
      (now.clockRate ?? kDefaultAudioClockRate);
  final lost = (now.packetsLost ?? 0) - (before.packetsLost ?? 0);
  final jitterMs = ((now.jitterSeconds ?? 0) * 1000).round();
  return 'Audio from $who was ${(share * 100).round()}% concealed over '
      '${seconds.round()} s ($lost packets lost, jitter $jitterMs ms): '
      'the network dropped it, the decoder filled the gap';
}

/// Samples every remote voice and our own on one timer; feeds [health] and
/// warns when a burst of static was the network.
class AudioGlitchWatch {
  AudioGlitchWatch({
    required this.sources,
    required this.log,
    this.note,
    this.nameOf = _same,
    this.local,
    this.shareSources,
    this.localIdOf = _localName,
    VoiceHealth? health,
    this.interval = kGlitchWatchInterval,
  }) : health = health ?? VoiceHealth();

  /// Every remote person's audio stats, by identity.
  final Map<String, AudioStatsSource> Function() sources;
  final String Function(String identity) nameOf;
  final AudioSendSource? local;

  /// Every remote person's screen-share audio, by identity.
  final Map<String, AudioStatsSource> Function()? shareSources;

  /// Read at each sample: the room's local identity does not exist yet when
  /// the watch is built.
  final String Function() localIdOf;
  final VoiceHealth health;
  final VoiceLog log;

  /// Takes a healthy minute's line, which stays out of [log] to keep the debug log for what went wrong.
  final void Function(String line)? note;
  final Duration interval;

  Timer? _timer;
  final _previous = <String, AudioReceiveSample>{};
  int _ticks = 0;

  static String _same(String identity) => identity;
  static String _localName() => 'local';

  String get localId => localIdOf();

  /// Whether the sampling timer is live.
  bool get running => _timer != null;

  void start() =>
      _timer ??= Timer.periodic(interval, (_) => unawaited(sample()));

  /// Stops sampling; a call that is only reconnecting keeps its history.
  void stop() {
    _timer?.cancel();
    _timer = null;
    _previous.clear();
    _ticks = 0;
    health.clearPing();
  }

  /// Ends the call: logs its summary and keeps it in [VoiceHealth.lastCall].
  void finish() {
    stop();
    for (final line in health.finish()) {
      log(line);
    }
  }

  Future<void> sample() async {
    final voices = sources();
    final shares = {
      for (final e in (shareSources?.call() ?? const {}).entries)
        '${e.key}$kShareKeySuffix': e.value,
    };
    final all = {...voices, ...shares};
    _previous.removeWhere((who, _) => !all.containsKey(who));
    health.retain(all.keys.toSet());
    final shareTick = ++_ticks % kShareSampleEvery == 0;
    for (final entry in {...voices, if (shareTick) ...shares}.entries) {
      await _sampleRemote(entry.key, entry.value);
    }
    await _sampleLocal();
    final line = health.takeMinuteLine();
    if (line == null) return;
    if (health.minuteIsNotable()) {
      log(line);
    } else {
      note?.call(line);
    }
  }

  Future<void> _sampleRemote(String id, AudioStatsSource source) async {
    try {
      final now = await source();
      if (now == null) {
        _previous.remove(id);
        health.skip(id);
        return;
      }
      final name = _labelOf(id);
      health.observeRemote(id, name, now, gated: !_isShare(id));
      final before = _previous[id];
      _previous[id] = now;
      final line = before == null ? null : concealmentLine(name, before, now);
      if (line != null) log(line, level: LogLevel.warning);
    } on Object catch (error, stack) {
      AppLog.swallowed(
        LogTag.voice,
        'Could not read remote audio stats',
        error,
        stack,
      );
      return;
    }
  }

  static bool _isShare(String key) => key.endsWith(kShareKeySuffix);

  String _labelOf(String key) => _isShare(key)
      ? '${nameOf(key.substring(0, key.length - kShareKeySuffix.length))} (share)'
      : nameOf(key);

  Future<void> _sampleLocal() async {
    final source = local;
    if (source == null) return;
    try {
      final now = await source();
      if (now != null) health.observeLocal(localIdOf(), now);
    } on Object catch (error, stack) {
      AppLog.swallowed(
        LogTag.voice,
        'Could not read local audio stats',
        error,
        stack,
      );
      return;
    }
  }
}
