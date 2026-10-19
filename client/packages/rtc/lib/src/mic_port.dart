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

  /// Opens the capture, or reopens a released one, and leaves it silent and
  /// published as muted until the next unmute.
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

class LiveKitMicPort implements MicPort {
  LiveKitMicPort(this._room);

  final lk.Room? Function() _room;
  final _lost = StreamController<void>.broadcast();

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
    if (track == null) return _publishMuted(options);
    await track.restartTrack(options);
    await track.disable();
  }

  /// Silent before it is published, so no sound leaves in the gap before the mute.
  Future<void> _publishMuted(lk.AudioCaptureOptions options) async {
    final participant = _room()?.localParticipant;
    if (participant == null) return;
    final track = await lk.LocalAudioTrack.create(options);
    try {
      await track.disable();
      await participant.publishAudioTrack(track);
    } catch (_) {
      await track.stop();
      rethrow;
    }
    await track.mute(stopOnMute: false);
  }

  @override
  Future<void> setEnabled(bool enabled, lk.AudioCaptureOptions? options) async {
    if (enabled && options != null && options.stopAudioCaptureOnMute) {
      // The reopen uses the track's own options, so they must be current.
      adoptOptions(options);
    }
    await _room()?.localParticipant?.setMicrophoneEnabled(
          enabled,
          audioCaptureOptions: options,
        );
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
