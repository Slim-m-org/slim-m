// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a voice session receives of remote video: how sharp, and which tiles.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/widgets.dart' show VoidCallback;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_api/api.dart' show LogLevel;

import 'remote_video_publication.dart';
import 'video_quality.dart';
import 'video_subscription_culler.dart';

/// What [VoiceVideoReceive] needs from the session that owns it.
class VoiceVideoReceiveHost {
  const VoiceVideoReceiveHost({
    required this.room,
    required this.disposed,
    required this.refresh,
    required this.syncStall,
    required this.diag,
  });

  final lk.Room? Function() room;
  final bool Function() disposed;
  final void Function() refresh;
  final void Function() syncStall;
  final void Function(String line, {LogLevel level}) diag;
}

/// Caps the sharpness of remote video and unsubscribes the tiles nobody shows.
class VoiceVideoReceive {
  VoiceVideoReceive(this._host) {
    culler = VideoSubscriptionCuller(onDue: applyInterest);
  }

  final VoiceVideoReceiveHost _host;
  late final VideoSubscriptionCuller culler;

  /// The adaptive-stream density the video views report.
  final density = ValueNotifier<lk.AdaptiveStreamPixelDensity>(
    lk.AdaptiveStreamPixelDensity.auto,
  );

  ReceiveVideoQuality _quality = ReceiveVideoQuality.auto;
  final _loweredSids = <String>{};
  final _enlarged = EnlargedVideo();

  ReceiveVideoQuality get quality => _quality;

  /// Caps the sharpness of the remote video you watch; live mid-call, and
  /// kept for the next join.
  void setQuality(ReceiveVideoQuality quality) {
    _quality = quality;
    culler.dwell = videoDwellFor(quality);
    density.value = pixelDensityFor(quality);
    _host.refresh();
  }

  /// Keeps the tile [tileKey] at full sharpness, whatever the receive quality, until the result is called.
  VoidCallback holdEnlarged(String tileKey) =>
      _enlarged.hold(tileKey, () => _host.disposed() ? null : _host.refresh());

  /// Declares which `'<kind>:<identity>'` tiles want video so the rest can be unsubscribed; null means no opinion.
  /// See [VideoSubscriptionCuller] for the timing.
  void setInterest(Set<String>? tileKeys) {
    culler.setInterest(tileKeys);
    applyInterest();
  }

  /// Keeps the screen-share (or camera) tiles named by [tileKeys] unsubscribed
  /// whatever the interest says, along with a share's own audio, so a viewer
  /// who stopped watching pays no bandwidth or decode for it.
  void setBlocked(Set<String> tileKeys) {
    culler.setBlocked(tileKeys);
    applyInterest();
  }

  /// Whatever a canvas last asked for was about the call that just ended.
  void resetForNewCall() {
    culler.setInterest(null);
    culler.setBlocked(const {});
  }

  /// Applies the receive quality to every remote video in [room].
  Future<void> applyQuality(lk.Room room) => applyReceiveVideoQuality(
        remoteVideoQualityRefs(room),
        _quality,
        _loweredSids,
        enlarged: _enlarged.keys,
      );

  /// Every remote video publication in the room, as the plain records
  /// `mapVideoSubscriptionRefs` turns into the tile keys the canvas's own
  /// `presenceTileKeys` keys a tile with.
  ///
  /// Walks `videoTrackPublications` only, so an audio publication is never
  /// reachable from here by construction - the first of the two independent
  /// guarantees that a cull can never silence anybody; the second is
  /// [VideoSubscriptionCuller]'s own refusal to act on a key whose kind is
  /// not in `cullableTrackKinds`.
  Iterable<RemoteVideoPublicationRef> _remoteVideoPublications(
    lk.Room room,
  ) sync* {
    for (final participant in room.remoteParticipants.values.toList()) {
      for (final pub in participant.videoTrackPublications.toList()) {
        yield (
          identity: participant.identity,
          source: pub.source,
          subscribed: pub.subscribed,
          subscribe: pub.subscribe,
          unsubscribe: pub.unsubscribe,
        );
      }
    }
  }

  /// Reconciles the room's remote video against whatever the last
  /// [setInterest] declared. Cheap enough to run on every room event, which is
  /// what it does: a publication's subscription state changes without the
  /// roster changing, so this cannot ride behind the roster's unchanged early return.
  void applyInterest() {
    final room = _host.room();
    if (room == null || _host.disposed()) return;
    culler.apply(mapVideoSubscriptionRefs(_remoteVideoPublications(room)));
    _applyShareAudioBlock(room);
    _host.syncStall();
  }

  /// A share's audio is its own publication, which the culler never sees, so a blocked share's is unsubscribed here and only here.
  void _applyShareAudioBlock(lk.Room room) {
    for (final participant in room.remoteParticipants.values) {
      final blocked = culler.blocked.contains(
        videoSubscriptionKey(
          identity: participant.identity,
          screenShare: true,
        ),
      );
      for (final pub in participant.audioTrackPublications) {
        if (pub.source != lk.TrackSource.screenShareAudio) continue;
        if (blocked == !pub.subscribed) continue;
        unawaited(
          (blocked ? pub.unsubscribe() : pub.subscribe()).catchError(
            (Object e) => _host.diag(
              'Could not change screen share audio: $e',
              level: LogLevel.warning,
            ),
          ),
        );
      }
    }
  }

  void dispose() {
    culler.dispose();
    density.dispose();
  }
}
