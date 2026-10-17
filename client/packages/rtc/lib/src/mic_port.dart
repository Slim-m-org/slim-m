// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The published microphone track as the session sees it, a seam so tests can
/// drive capture restarts without a native audio stack behind livekit.
library;

import 'dart:async';

import 'package:livekit_client/livekit_client.dart' as lk;

abstract interface class MicPort {
  /// Whether a microphone track has been published.
  bool get hasTrack;

  /// Whether that track is published and not muted.
  bool get open;

  Future<void> setEnabled(bool enabled, lk.AudioCaptureOptions? options);

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
  Future<void> setEnabled(bool enabled, lk.AudioCaptureOptions? options) async {
    await _room()?.localParticipant?.setMicrophoneEnabled(
          enabled,
          audioCaptureOptions: options,
        );
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
