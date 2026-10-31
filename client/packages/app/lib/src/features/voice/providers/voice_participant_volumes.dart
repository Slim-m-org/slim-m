// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_participant_volume_store.dart';
import 'volume_drag_throttle.dart';

/// Per-participant playback volume.
class VoiceParticipantVolumes {
  VoiceParticipantVolumes(this._session, this._ref, this._log);

  final VoiceSession _session;
  final Ref _ref;
  final void Function(String message, {Object? detail}) _log;

  final Map<(String, LocalAudioChannel), TrailingThrottle<double>> _drags = {};
  final Set<(String, LocalAudioChannel)> _failing = {};

  /// Whether this host can change one participant's volume at all; see
  /// `audio_gain.dart` in the rtc package.
  bool get supportsParticipantVolume => _session.supportsParticipantVolume;

  /// [identity]'s playback gain for this listener, 1.0 being unchanged.
  double volumeFor(String identity) => _session.volumeFor(identity);

  /// [identity]'s screen share audio gain, apart from their voice.
  double screenVolumeFor(String identity) => _session.screenVolumeFor(identity);

  bool isScreenAudioMuted(String identity) =>
      _session.isScreenAudioMuted(identity);

  Future<void> setScreenAudioMuted(String identity, bool muted) =>
      _session.setScreenAudioMuted(identity, muted);

  /// Whether [identity] is publishing screen share audio right now.
  bool hasScreenAudio(String identity) => _session.hasScreenAudio(identity);

  /// Why the last volume change to [identity] did not land, or null.
  Object? volumeFailureFor(
    String identity, {
    LocalAudioChannel channel = LocalAudioChannel.voice,
  }) => _session.volumeFailureFor(
    identity,
    screen: channel == LocalAudioChannel.screen,
  );

  /// Sets and saves [identity]'s voice volume for this listener only.
  ///
  /// Deliberately does not rebuild the controller state: this is dragged, and
  /// republishing the roster on every frame is what makes the call screen
  /// jank. The slider owns its own value while it moves.
  Future<void> setVolumeFor(String identity, double volume) =>
      _commitVolume(identity, volume, LocalAudioChannel.voice);

  /// Sets and saves [identity]'s screen share audio volume.
  Future<void> setScreenVolumeFor(String identity, double volume) =>
      _commitVolume(identity, volume, LocalAudioChannel.screen);

  /// A mid-drag value: applied on a short throttle and never saved. The
  /// release goes through [setVolumeFor] or [setScreenVolumeFor].
  Future<void> dragVolumeFor(
    String identity,
    double volume, {
    LocalAudioChannel channel = LocalAudioChannel.voice,
  }) => _dragThrottle(identity, channel).push(clampParticipantVolume(volume));

  TrailingThrottle<double> _dragThrottle(
    String identity,
    LocalAudioChannel channel,
  ) => _drags.putIfAbsent((
    identity,
    channel,
  ), () => TrailingThrottle((v) => _applyVolume(identity, v, channel)));

  Future<void> _commitVolume(
    String identity,
    double volume,
    LocalAudioChannel channel,
  ) async {
    final clamped = clampParticipantVolume(volume);
    _dragThrottle(identity, channel).cancel();
    unawaited(saveParticipantVolume(_ref, identity, clamped, channel: channel));
    await _applyVolume(identity, clamped, channel);
  }

  Future<void> _applyVolume(
    String identity,
    double volume,
    LocalAudioChannel channel,
  ) async {
    final screen = channel == LocalAudioChannel.screen;
    await (screen
        ? _session.setScreenVolumeFor(identity, volume)
        : _session.setVolumeFor(identity, volume));
    final failure = _session.volumeFailureFor(identity, screen: screen);
    if (failure == null) {
      _failing.remove((identity, channel));
    } else if (_failing.add((identity, channel))) {
      _log(
        'Could not change a participant volume',
        detail: '${channel.name} audio for $identity: $failure',
      );
    }
  }

  /// Seeds the saved volumes into the session before any call exists, so
  /// someone turned down stays turned down after a restart.
  Future<void> restoreParticipantVolumes() async {
    final voice = await loadParticipantVolumes(_ref);
    for (final entry in voice.entries) {
      await _session.setVolumeFor(entry.key, entry.value);
    }
    final screen = await loadParticipantVolumes(
      _ref,
      channel: LocalAudioChannel.screen,
    );
    for (final entry in screen.entries) {
      await _session.setScreenVolumeFor(entry.key, entry.value);
    }
  }

  void dispose() {
    for (final throttle in _drags.values) {
      throttle.cancel();
    }
  }
}
