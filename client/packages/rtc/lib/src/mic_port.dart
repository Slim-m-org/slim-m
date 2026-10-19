// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The published microphone track as the session sees it, a seam so tests can
/// drive capture restarts without a native audio stack behind livekit.
library;

import 'dart:async';

import 'package:flutter/services.dart' show MethodChannel;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_api/api.dart' show AppLog, LogTag;

import 'mic_recovery.dart' show senderLevelToDb;

abstract interface class MicPort {
  /// Whether a microphone track has been published.
  bool get hasTrack;

  /// Whether that track is published and not muted.
  bool get open;

  Future<void> setEnabled(bool enabled, lk.AudioCaptureOptions? options);

  /// The capture's level in dBFS from the sender's own stats, or null when the
  /// platform reports none; only exact digital silence reads as the floor.
  Future<double?> senderLevelDb();

  /// Stops the capture of the muted track, keeping it published so an unmute
  /// can reopen it.
  Future<void> release();

  /// Reopens a released capture and leaves it silent until the next unmute.
  Future<void> reopenMuted(lk.AudioCaptureOptions options);

  /// Reopens the capture with [options].
  Future<void> restart(lk.AudioCaptureOptions options);

  /// Makes [options] what the track's next reopen, such as a device switch,
  /// uses.
  void adoptOptions(lk.AudioCaptureOptions options);

  /// Fires when the published track ended or was unpublished by something
  /// other than [discard].
  Stream<void> get lost;

  /// Hands the port every room event, so it can tell when the track is lost.
  void onRoomEvent(lk.RoomEvent event);

  /// Unpublishes the track without announcing it as a loss, so a fresh one
  /// can take its place.
  Future<void> discard();
}

/// A port that can open the capture before the room is up, so a join does not
/// wait for the connect to start the microphone.
abstract interface class MicPreopen {
  /// Opens the capture with [options] now; the next [MicPort.setEnabled] that
  /// asks for the same options publishes it instead of opening another.
  /// Answers whether the capture opened.
  Future<bool> preopen(lk.AudioCaptureOptions options);

  /// Closes a preopened capture nobody published.
  Future<void> discardPreopened();
}

/// The capture opened ahead of the connect, until a publish claims it.
class PreopenSlot<T extends Object> {
  lk.AudioCaptureOptions? _options;
  Future<T?>? _capture;

  /// Holds [capture] as opened with [options]; returns the one it replaces,
  /// which the caller must close.
  Future<T?>? hold(lk.AudioCaptureOptions options, Future<T?> capture) {
    final replaced = clear();
    _options = options;
    _capture = capture;
    return replaced;
  }

  /// Empties the slot and returns what it held, to close.
  Future<T?>? clear() {
    final held = _capture;
    _capture = null;
    _options = null;
    return held;
  }

  /// Empties the slot. The capture comes back as [match] when it was opened
  /// the way [wanted] asks and [usable], otherwise as [stale], to be closed.
  ({Future<T?>? match, Future<T?>? stale}) claim(
    lk.AudioCaptureOptions wanted, {
    required bool usable,
  }) {
    final options = _options;
    final held = clear();
    if (held == null || options == null) return (match: null, stale: null);
    final fits = usable && sameMicCapture(options, wanted);
    return (match: fits ? held : null, stale: fits ? null : held);
  }
}

/// Whether a capture opened with [opened] can stand in for one asked for with
/// [wanted]: same device, same processing, same mute policy.
bool sameMicCapture(
  lk.AudioCaptureOptions opened,
  lk.AudioCaptureOptions wanted,
) =>
    opened.deviceId == wanted.deviceId &&
    opened.noiseSuppression == wanted.noiseSuppression &&
    opened.echoCancellation == wanted.echoCancellation &&
    opened.autoGainControl == wanted.autoGainControl &&
    opened.highPassFilter == wanted.highPassFilter &&
    opened.noiseSuppressionMode == wanted.noiseSuppressionMode &&
    opened.echoCancellationMode == wanted.echoCancellationMode &&
    opened.autoGainControlMode == wanted.autoGainControlMode &&
    opened.highPassFilterMode == wanted.highPassFilterMode &&
    opened.voiceIsolation == wanted.voiceIsolation &&
    opened.typingNoiseDetection == wanted.typingNoiseDetection &&
    opened.stopAudioCaptureOnMute == wanted.stopAudioCaptureOnMute &&
    identical(opened.processor, wanted.processor);

class LiveKitMicPort implements MicPort, MicPreopen {
  LiveKitMicPort(
    this._room, {
    bool? preopens,
    bool? mobile,
  }) : preopens = preopens ?? !(mobile ?? lk.lkPlatformIsMobile());

  /// False on phones, where opening native capture before the connect is
  /// untried against iOS CallKit's audio-session order and Android's audio
  /// mode; also false where the room is a stand-in with no capture behind it.
  final bool preopens;

  final lk.Room? Function() _room;
  final _lost = StreamController<void>.broadcast();
  final _slot = PreopenSlot<lk.LocalAudioTrack>();

  @override
  Future<bool> preopen(lk.AudioCaptureOptions options) async {
    if (!preopens) return false;
    unawaited(_close(_slot.clear()));
    final capture = Future.sync(() => lk.LocalAudioTrack.create(options))
        .then<lk.LocalAudioTrack?>(
      (track) => track,
      onError: (Object e, StackTrace stack) {
        AppLog.swallowed(LogTag.voice,
            'Could not open the microphone ahead of the connect', e, stack);
        return null;
      },
    );
    unawaited(_close(_slot.hold(options, capture)));
    return await capture != null;
  }

  @override
  Future<void> discardPreopened() => _close(_slot.clear());

  Future<void> _close(Future<lk.LocalAudioTrack?>? capture) async {
    final track = await capture;
    if (track == null) return;
    await track.stop();
    await _stopNativeRecording();
  }

  /// The preopened capture, when it is still wanted and was opened the way
  /// [options] asks; any other is closed so the caller opens its own.
  Future<lk.LocalAudioTrack?> _takePreopened(
      lk.AudioCaptureOptions options) async {
    final claimed = _slot.claim(
      options,
      usable: _publication == null && _room() != null,
    );
    unawaited(_close(claimed.stale));
    return claimed.match;
  }

  @override
  Stream<void> get lost => _lost.stream;

  @override
  void onRoomEvent(lk.RoomEvent event) {
    if (event is lk.LocalTrackUnpublishedEvent &&
        event.publication.source == lk.TrackSource.microphone) {
      _lost.add(null);
    }
  }

  @override
  Future<void> discard() async {
    final publication = _publication;
    if (publication == null) return;
    await _room()
        ?.localParticipant
        ?.removePublishedTrack(publication.sid, notify: false);
  }

  lk.LocalTrackPublication<lk.LocalAudioTrack>? get _publication {
    final all = _room()?.localParticipant?.audioTrackPublications;
    for (final p in all ?? <lk.LocalTrackPublication<lk.LocalAudioTrack>>[]) {
      if (p.source == lk.TrackSource.microphone) return p;
    }
    return null;
  }

  @override
  bool get hasTrack => _publication != null;

  @override
  bool get open {
    final pub = _publication;
    return pub != null && !pub.muted;
  }

  @override
  Future<void> release() async {
    await _publication?.track?.stop();
    await _stopNativeRecording();
  }

  Future<void> _stopNativeRecording() async {
    if (!_recordsUntilToldToStop) return;
    try {
      await _nativeChannel
          .invokeMethod<void>('stopLocalRecording', <String, dynamic>{});
    } on Object catch (e) {
      AppLog.swallowed(
          LogTag.voice, 'Could not stop native recording', e, null);
    }
  }

  /// livekit_client starts the device recording itself on these platforms
  /// and only a stop call ends it, whatever happens to the track.
  static bool get _recordsUntilToldToStop =>
      lk.lkPlatformSupportsExplicitAudioRecordingStart();

  static const _nativeChannel = MethodChannel('livekit_client');

  @override
  Future<void> reopenMuted(lk.AudioCaptureOptions options) async {
    final track = _publication?.track;
    if (track == null) return;
    await track.restartTrack(options);
    await track.disable();
  }

  @override
  Future<void> setEnabled(bool enabled, lk.AudioCaptureOptions? options) async {
    if (enabled && options != null && options.stopAudioCaptureOnMute) {
      // The reopen uses the track's own options, so they must be current.
      adoptOptions(options);
    }
    if (enabled && options != null && await _publishPreopened(options)) return;
    await _room()?.localParticipant?.setMicrophoneEnabled(
          enabled,
          audioCaptureOptions: options,
        );
  }

  Future<bool> _publishPreopened(lk.AudioCaptureOptions options) async {
    final track = await _takePreopened(options);
    if (track == null) return false;
    try {
      await _room()?.localParticipant?.publishAudioTrack(track);
    } on Object {
      await track.stop();
      rethrow;
    }
    return true;
  }

  @override
  Future<double?> senderLevelDb() async {
    final stats = await _publication?.track?.getSenderStats();
    final level = stats?.audioSourceStats?.audioLevel;
    return level == null ? null : senderLevelToDb(level.toDouble());
  }

  @override
  Future<void> restart(lk.AudioCaptureOptions options) async {
    await _publication?.track?.restartTrack(options);
  }

  @override
  void adoptOptions(lk.AudioCaptureOptions options) {
    _publication?.track?.currentOptions = options;
  }
}
