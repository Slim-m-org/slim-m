// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The first seconds of a call, read into its diagnostics timeline.
///
/// A join that connects but never gets audio flowing ends before the
/// once-a-minute health line exists, so this reads the call's audio a few
/// seconds after each connect and again after every event that could change
/// it: what the engine and the platform audio session were doing, what the
/// microphone sent, and what each remote voice delivered. It only reads.
library;

import 'dart:async';

import 'package:slimm_api/api.dart' show AppLog, LogLevel, LogTag;

import 'audio_glitch_watch.dart';
import 'voice_log.dart';
import 'voice_models.dart';

/// When the probe reads after each connect.
const List<Duration> kJoinProbeDelays = [
  Duration(seconds: 3),
  Duration(seconds: 10),
  Duration(seconds: 30),
];

/// One remote voice as the probe reads it: [blocked] says why nothing can be
/// read ('muted by them', 'not subscribed'), and [playing] whether this
/// listener lets it play.
typedef RemoteVoiceProbe = ({
  String? blocked,
  bool playing,
  AudioStatsSource stats,
});

/// What [JoinAudioProbe] needs from the session that owns it.
class JoinAudioProbeHost {
  const JoinAudioProbeHost({
    required this.local,
    required this.remotes,
    required this.micWanted,
    required this.deafened,
    required this.engine,
    required this.note,
  });

  final AudioSendSource local;

  /// Each remote voice by the name the report already shows.
  final Map<String, RemoteVoiceProbe> Function() remotes;
  final bool Function() micWanted;
  final bool Function() deafened;

  /// The audio engine as one phrase, or null where the platform reports none.
  final String? Function() engine;

  /// Files a line into the call's timeline and the debug log.
  final VoiceLog note;
}

class JoinAudioProbe {
  JoinAudioProbe(
    this._host, {
    this.delays = kJoinProbeDelays,
    Stream<String>? engineChanges,
  }) : _engineChanges = engineChanges;

  final JoinAudioProbeHost _host;
  final List<Duration> delays;
  final Stream<String>? _engineChanges;

  /// The platform audio session as one phrase; the app sets it where it has a native reader.
  Future<String?> Function()? audioSession;

  StreamSubscription<String>? _engine;
  final _timers = <Timer>[];
  bool _live = false;
  bool _checking = false;
  String? _pending;

  /// Follows the call: live from the join, read on a schedule from the
  /// connect, quiet once it ends.
  void sync(VoiceSessionState state) {
    switch (state) {
      case VoiceSessionState.connecting:
        _note('Joining');
        _setLive(true);
      case VoiceSessionState.connected:
        _note('Connected');
        _setLive(true);
        _arm();
      case VoiceSessionState.idle:
        _note('Left');
        _setLive(false);
      case VoiceSessionState.failed:
        _note('Failed');
        _setLive(false);
    }
  }

  /// Files an event and reads the audio right after it.
  void noteEvent(String line) {
    _note(line);
    unawaited(check('after an event'));
  }

  /// Runs a mute or deafen toggle and files whether it took; one between
  /// calls is a preference, not something the last call did.
  Future<bool> noteToggle(String what, Future<bool> toggle) async {
    final ok = await toggle;
    if (_live) noteEvent(ok ? what : '$what did not take');
    return ok;
  }

  /// Reads the audio into one line; reads asked for while one runs collapse into one more.
  Future<void> check(String reason) async {
    if (_checking) {
      _pending = reason;
      return;
    }
    _checking = true;
    String? next = reason;
    try {
      while (next != null && _live) {
        final line = await _read('audio check', _snapshot) ?? 'unreadable';
        if (_live) {
          _host.note('Audio check ($next): $line', level: LogLevel.debug);
        }
        next = _pending;
        _pending = null;
      }
    } finally {
      _checking = false;
    }
  }

  void dispose() => _setLive(false);

  void _note(String line) => _host.note(line);

  void _setLive(bool live) {
    _live = live;
    if (live) {
      _engine ??= _engineChanges?.listen(noteEvent);
      return;
    }
    _cancelTimers();
    _pending = null;
    unawaited(_engine?.cancel());
    _engine = null;
  }

  void _arm() {
    _cancelTimers();
    for (final delay in delays) {
      _timers.add(
        Timer(
            delay, () => unawaited(check('${delay.inSeconds}s after connect'))),
      );
    }
  }

  void _cancelTimers() {
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
  }

  Future<String> _snapshot() async {
    final session =
        await _read('audio session', () async => audioSession?.call());
    final parts = <String>[
      'mic ${_onOff(_host.micWanted())}${_host.deafened() ? ', deafened' : ''}',
      if (_host.engine() case final engine?) engine,
      if (session != null) session,
      _sentPart(await _read('mic stats', _host.local)),
      ...await _remoteParts(),
    ];
    return parts.join(' | ');
  }

  Future<List<String>> _remoteParts() async {
    final remotes = _host.remotes();
    if (remotes.isEmpty) return const ['no remote voice'];
    return [
      for (final MapEntry(key: name, value: probe) in remotes.entries)
        '$name: ${await _remotePart(probe)}',
    ];
  }

  Future<String> _remotePart(RemoteVoiceProbe probe) async {
    if (probe.blocked case final blocked?) return blocked;
    final sample = await _read('remote voice stats', probe.stats);
    final off = probe.playing ? '' : ', playback off';
    if (sample == null) return 'no stats$off';
    return '${_count(sample.packetsReceived)} packets in, '
        'level ${_level(sample.audioLevel)}$off';
  }

  Future<T?> _read<T>(String what, Future<T?> Function() read) async {
    try {
      return await read();
    } on Object catch (error, stack) {
      AppLog.swallowed(
          LogTag.voice, 'No $what for the join check', error, stack);
      return null;
    }
  }
}

String _sentPart(AudioSendSample? sample) => sample == null
    ? 'no mic track'
    : 'sent ${_count(sample.packetsSent)} packets, '
        'level ${_level(sample.audioLevel)}';

String _onOff(bool on) => on ? 'on' : 'off';

String _count(num? n) => n == null ? '?' : '${n.round()}';

String _level(num? level) => level == null ? '?' : level.toStringAsFixed(3);
