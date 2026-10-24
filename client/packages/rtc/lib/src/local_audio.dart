// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What one listener has done about what reaches their own ears: deafen,
/// silence one person, or turn one person up or down. All of it is local and
/// never announced, so nobody learns they were muted.
///
/// It is reapplied on every room event so a rejoined or resubscribed track
/// keeps the listener's choice, skipping a push only when the track already
/// has that state, and never trusting that across a replaced track. Why it reads the track back rather than trusting what it
/// asked for is in docs/research/mic-handling.md.
library;

import 'dart:async';

import 'package:livekit_client/livekit_client.dart' as lk;

import 'audio_apply_cache.dart';
import 'audio_event_scope.dart';
import 'audio_gain.dart';
import 'package:slimm_api/api.dart' show LogLevel, LogTag, reportFailure;

import 'voice_log.dart';

/// Which of one person's audio a gain or mute is about: their microphone, or
/// the sound of the screen they are sharing. Keyed apart because they are
/// separate publications that a listener balances separately.
enum LocalAudioChannel { voice, screen }

/// One subscribed remote audio track as plain closures, so tests can see
/// which calls are made. [track] keys the volume cache and must be the
/// object the closures act on; [isAudible] reads its current state cheaply.
typedef LocalAudioRef = ({
  String identity,
  LocalAudioChannel channel,
  String trackId,
  Object track,
  bool Function() isAudible,
  Future<void> Function() enable,
  Future<void> Function() disable,
  Future<void> Function() startForwarding,
  Future<void> Function() stopForwarding,
  Future<Object?> Function(double volume) setVolume,
});

class LocalAudioState {
  LocalAudioState({
    this.retryDelays = const [
      Duration(milliseconds: 100),
      Duration(milliseconds: 400),
      Duration(seconds: 1),
    ],
  });

  /// Waits before each retry of a failed push; once spent, retrying stops
  /// until the mute, deafen or volume choices change.
  final List<Duration> retryDelays;

  /// Receives one line per gain push, for the app's debug log.
  VoiceLog? log;

  /// Silences every remote participant.
  bool deafened = false;

  /// Identities silenced individually, microphone and screen audio together.
  final Set<String> muted = {};

  /// Identities whose screen share audio alone is silenced.
  final Set<String> screenMuted = {};

  /// Per-identity microphone gain, absent meaning [kDefaultParticipantVolume].
  ///
  /// Deliberately not carried on the participant value type: that list is
  /// compared by value to decide whether to push a new roster to every
  /// listener, so a gain field would turn each pixel of a slider drag into a
  /// full roster rebuild.
  final Map<String, double> volumes = {};

  /// Per-identity screen share audio gain, kept apart from [volumes].
  final Map<String, double> screenVolumes = {};

  Map<String, double> _volumesOf(LocalAudioChannel channel) =>
      channel == LocalAudioChannel.screen ? screenVolumes : volumes;

  double volumeFor(
    String identity, {
    LocalAudioChannel channel = LocalAudioChannel.voice,
  }) =>
      _volumesOf(channel)[identity] ?? kDefaultParticipantVolume;

  void setVolumeFor(
    String identity,
    double volume, {
    LocalAudioChannel channel = LocalAudioChannel.voice,
  }) {
    _volumesOf(channel)[identity] = clampParticipantVolume(volume);
    _cache.forget(identity: identity, channel: channel, volumeOnly: true);
  }

  /// Distrusts what was pushed to [identity] (everyone for [everyone]): a
  /// room event may have put a new native receiver under the same Dart track.
  void trackReplaced(String identity) {
    _cache.forget(identity: identity == everyone ? null : identity);
  }

  /// People with a saved gain but no subscribed track to apply it to yet.
  final Set<(String, LocalAudioChannel)> pending = {};

  Timer? _retryTimer;
  int _attempts = 0;
  bool _gaveUp = false;
  String? _retryTarget;

  /// Stops any scheduled retry; the state itself stays usable.
  void cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  void setMuted(String identity, bool value) {
    value ? muted.add(identity) : muted.remove(identity);
  }

  bool isMuted(String identity) => muted.contains(identity);

  /// The gain a track must start at before the next [applyTo] pass reaches it,
  /// or null when it may play untouched. Silence is 0.
  double? arrivalGain(String identity, LocalAudioChannel channel) {
    final silent = deafened ||
        muted.contains(identity) ||
        (channel == LocalAudioChannel.screen && screenMuted.contains(identity));
    if (silent) return 0;
    final volume = volumeFor(identity, channel: channel);
    return volume == kDefaultParticipantVolume ? null : volume;
  }

  /// Holds the freshly attached track [trackId] at its [arrivalGain], tapered
  /// as the later pass will taper it, through [hold], so a listener's choice is in force from its first sample.
  void holdArrival(
    Iterable<LocalAudioRef> refs,
    String trackId,
    void Function(String trackId, double gain) hold,
  ) {
    for (final ref in refs) {
      if (ref.trackId != trackId) continue;
      final gain = arrivalGain(ref.identity, ref.channel);
      if (gain != null) hold(trackId, perceptualParticipantGain(gain));
    }
  }

  void setScreenMuted(String identity, bool value) {
    value ? screenMuted.add(identity) : screenMuted.remove(identity);
  }

  bool isScreenMuted(String identity) => screenMuted.contains(identity);

  /// The last gain failure for one person's channel, or null when its most
  /// recent apply went through (or nothing was subscribed to apply to).
  Object? failureFor(
    String identity, {
    LocalAudioChannel channel = LocalAudioChannel.voice,
  }) =>
      _failures[(identity, channel)];

  final Map<(String, LocalAudioChannel), Object> _failures = {};

  /// Applies all of it to every remote audio track currently subscribed,
  /// returning the last failure or null.
  ///
  /// Failures are returned rather than thrown because the caller fires this
  /// without awaiting from a room-event handler, where a throw would become
  /// an unhandled zone error instead of something anybody could act on.
  ///
  /// Silence is two calls. The media track's `enabled` flag is local and
  /// instant. The publication's `disable()` then tells the SFU to stop
  /// forwarding the track, so nothing is sent or decoded for a listener who
  /// cannot hear it; it keeps the subscription, and sound returns on one
  /// signalling round trip with no renegotiation.
  Future<Object?> applyTo(lk.Room room) => applyToRefs(refsOf(room));

  /// Every subscribed remote audio track in [room], as [LocalAudioRef]s.
  ///
  /// Walks copies: callers await between refs, and a join or leave in that gap
  /// threw a concurrent modification that stopped the rest of the pass.
  Iterable<LocalAudioRef> refsOf(lk.Room room) sync* {
    for (final participant in room.remoteParticipants.values.toList()) {
      for (final publication in participant.audioTrackPublications.toList()) {
        final track = publication.track;
        if (track == null) continue;
        yield (
          identity: participant.identity,
          channel: publication.source == lk.TrackSource.screenShareAudio
              ? LocalAudioChannel.screen
              : LocalAudioChannel.voice,
          trackId: track.mediaStreamTrack.id ?? '',
          track: track.mediaStreamTrack,
          isAudible: () => track.mediaStreamTrack.enabled,
          enable: track.enable,
          disable: track.disable,
          startForwarding: publication.enable,
          stopForwarding: publication.disable,
          setVolume: (volume) => applyParticipantVolume(track, volume),
        );
      }
    }
  }

  /// Whether [identity] publishes screen share audio at all, subscribed or not.
  bool hasScreenAudio(lk.Room room, String identity) =>
      room.remoteParticipants[identity]?.audioTrackPublications.any(
        (p) => p.source == lk.TrackSource.screenShareAudio,
      ) ??
      false;

  bool _busy = false;
  Completer<Object?>? _queued;
  Iterable<LocalAudioRef> _latestRefs = const [];

  /// The half of [applyTo] worth testing, over an explicit track list.
  ///
  /// One pass runs at a time. A call made mid-pass does not overlap it: it
  /// queues one follow-up pass that reads the stored state afresh, so however
  /// fast a slider is dragged the last value set is the last one applied.
  Future<Object?> applyToRefs(Iterable<LocalAudioRef> refs) {
    _latestRefs = refs;
    if (_busy) return (_queued ??= Completer<Object?>()).future;
    return _drain();
  }

  Future<Object?> _drain() async {
    _busy = true;
    Object? result;
    try {
      do {
        final waiting = _queued;
        _queued = null;
        result = await _pass(_latestRefs);
        waiting?.complete(result);
      } while (_queued != null);
    } finally {
      _busy = false;
    }
    _planRetry();
    return result;
  }

  void _planRetry() {
    if (_failures.isEmpty) {
      cancelRetry();
      _attempts = 0;
      _gaveUp = false;
      _retryTarget = null;
      return;
    }
    final target = _targetFingerprint();
    if (target != _retryTarget) {
      cancelRetry();
      _attempts = 0;
      _gaveUp = false;
      _retryTarget = target;
    }
    if (_retryTimer != null || _gaveUp) return;
    if (_attempts >= retryDelays.length) {
      log?.call(
        'Volume still failing after $_attempts retries for '
        '${_failures.keys.map((k) => '${k.$1}/${k.$2.name}').join(', ')}; '
        'giving up until the audio settings change',
        level: LogLevel.warning,
      );
      _gaveUp = true;
      return;
    }
    _retryTimer = Timer(retryDelays[_attempts++], () {
      _retryTimer = null;
      unawaited(applyToRefs(_latestRefs));
    });
  }

  String _targetFingerprint() => [
        deafened,
        (muted.toList()..sort()).join(','),
        (screenMuted.toList()..sort()).join(','),
        for (final channel in LocalAudioChannel.values)
          (_volumesOf(channel)
                  .entries
                  .map((e) => '${e.key}=${e.value}')
                  .toList()
                ..sort())
              .join(','),
      ].join('|');

  Future<Object?> _pass(Iterable<LocalAudioRef> refs) async {
    Object? failure;
    final present = <(String, LocalAudioChannel)>{};
    for (final ref in refs) {
      present.add((ref.identity, ref.channel));
      try {
        failure = await _applyOne(ref) ?? failure;
      } catch (e, stack) {
        reportFailure(LogTag.voice, 'apply participant volumes', e, stack);
        failure = e;
      }
    }
    _failures.removeWhere((key, _) => !present.contains(key));
    pending
      ..clear()
      ..addAll(_slotsWithGain().where((k) => !present.contains(k)));
    return failure;
  }

  Iterable<(String, LocalAudioChannel)> _slotsWithGain() sync* {
    for (final channel in LocalAudioChannel.values) {
      for (final entry in _volumesOf(channel).entries) {
        if (entry.value != kDefaultParticipantVolume) {
          yield (entry.key, channel);
        }
      }
    }
  }

  Future<Object?> _applyOne(LocalAudioRef ref) async {
    final key = (ref.identity, ref.channel);
    final silence = deafened ||
        muted.contains(ref.identity) ||
        (ref.channel == LocalAudioChannel.screen &&
            screenMuted.contains(ref.identity));
    final audible = ref.isAudible();
    final volume = volumeFor(ref.identity, channel: ref.channel);
    final forward = !silence && volume > 0;

    final forwardFailure = await _setForwarding(ref, forward);
    if (silence) return _silence(ref, forwardFailure, audible: audible);

    if (audible && _cache.volumeOf(ref) == volume && forwardFailure == null) {
      return null;
    }

    final here = await _enableAt(ref, volume, forwardFailure);
    here == null ? _failures.remove(key) : _failures[key] = here;
    return here;
  }

  Future<Object?> _silence(
    LocalAudioRef ref,
    Object? forwardFailure, {
    required bool audible,
  }) async {
    Object? failure = forwardFailure;
    if (audible) {
      try {
        await ref.disable();
      } catch (e, stack) {
        reportFailure(LogTag.voice, "mute a participant's audio", e, stack);
        failure = e;
      }
    }
    // Whatever was believed about gain stops being true once it is silent.
    _cache.setVolume(ref, null);
    return failure;
  }

  Future<Object?> _enableAt(
    LocalAudioRef ref,
    double volume,
    Object? forwardFailure,
  ) async {
    Object? here = forwardFailure;
    try {
      await ref.enable();
    } catch (e, stack) {
      reportFailure(LogTag.voice, "unmute a participant's audio", e, stack);
      here = e;
    }
    // After the enable, never before: re-enabling can reset source volume.
    here = await ref.setVolume(volume) ?? here;
    log?.call(
      'Volume x$volume for ${ref.channel.name} audio of ${ref.identity} '
      '(track ${ref.trackId}): ${here == null ? 'applied' : 'failed: $here'}',
      level: here == null ? LogLevel.debug : LogLevel.warning,
    );

    // Remembered only if it both went cleanly and can be seen to have landed.
    _cache.setVolume(ref, here == null && ref.isAudible() ? volume : null);
    return here;
  }

  /// Tells the SFU to send or stop sending [ref], once per change.
  Future<Object?> _setForwarding(LocalAudioRef ref, bool forward) async {
    if (_cache.forwardingOf(ref) == forward) return null;
    try {
      await (forward ? ref.startForwarding() : ref.stopForwarding());
      _cache.setForwarding(ref, forward);
      return null;
    } catch (e, stack) {
      reportFailure(
        LogTag.voice,
        forward ? 'resume forwarding audio' : 'stop forwarding audio',
        e,
        stack,
      );
      return e;
    }
  }

  final AudioApplyCache _cache = AudioApplyCache();
}
