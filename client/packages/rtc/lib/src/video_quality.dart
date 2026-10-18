// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The two video quality choices a person makes for themselves: how sharp
/// the video they watch is, and how sharp their own camera is.
///
/// Both are pure functions of a choice, so what reaches LiveKit is testable
/// with no room: [applyReceiveVideoQuality] takes closures the way
/// `mapVideoSubscriptionRefs` does, and [cameraCaptureOptionsFor] only needs
/// the capture options a real room would have supplied.
library;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/widgets.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import 'video_publish_options.dart';

/// How sharp the remote video you watch should be.
enum ReceiveVideoQuality {
  /// The top layer whatever the tile size; only the network can lower it.
  max,

  /// No cap: LiveKit picks the layer from the tile size and the network.
  auto,

  /// A medium layer for cameras, the full one for shares.
  balanced,

  /// The smallest layer that still reads: low for cameras, medium for shares.
  dataSaver;

  /// The layer ceiling for a camera or, with [screenShare], a screen share.
  ///
  /// Shares stay one step sharper than cameras because the lowest layer of a
  /// screen is unreadable text, which defeats watching one at all.
  lk.VideoQuality layerFor({required bool screenShare}) => switch (this) {
        max || auto => lk.VideoQuality.HIGH,
        balanced => screenShare ? lk.VideoQuality.HIGH : lk.VideoQuality.MEDIUM,
        dataSaver => screenShare ? lk.VideoQuality.MEDIUM : lk.VideoQuality.LOW,
      };
}

/// The room options every call starts from, whatever [ReceiveVideoQuality] is.
///
/// Adaptive stream stays on even for Max: it is what pauses a track no view
/// has mounted, and turning it off left hidden video decoding at full size.
lk.RoomOptions receiveRoomOptions() => lk.RoomOptions(
      adaptiveStream: true,
      dynacast: true,
      defaultVideoPublishOptions: cameraPublishOptions(),
    );

/// Large enough that a tile's drawn size never undercuts the top simulcast
/// layer, so LiveKit's adaptive sizing yields to the HIGH quality Max asks for
/// while an unmounted view still pauses the track.
const maxQualityPixelDensity = 16.0;

/// The adaptive-stream density a renderer reports for [quality].
lk.AdaptiveStreamPixelDensity pixelDensityFor(ReceiveVideoQuality quality) =>
    quality == ReceiveVideoQuality.max
        ? const lk.AdaptiveStreamPixelDensity.fixed(maxQualityPixelDensity)
        : lk.AdaptiveStreamPixelDensity.auto;

/// Builds with the live density, or the default when no session supplies one.
Widget withReceiveDensity(
  ValueListenable<lk.AdaptiveStreamPixelDensity>? density,
  Widget Function(lk.AdaptiveStreamPixelDensity density) build,
) =>
    density == null
        ? build(lk.AdaptiveStreamPixelDensity.auto)
        : ValueListenableBuilder<lk.AdaptiveStreamPixelDensity>(
            valueListenable: density,
            builder: (context, value, child) => build(value),
          );

/// One remote video publication reduced to what quality selection needs.
typedef RemoteVideoQualityRef = ({
  String sid,
  lk.TrackSource source,
  bool subscribed,
  Future<void> Function(lk.VideoQuality quality) setQuality,
});

/// Applies [quality] to every subscribed camera and screen share in
/// [publications]; other sources are left to LiveKit.
///
/// A publication is only touched when a layer below the top is wanted, or to
/// undo one this session lowered ([lowered] holds those sids and is updated).
/// An explicit quality makes LiveKit bypass its drawn-size adaptive sizing
/// whenever layer info is missing, so Auto must never set one on a publication
/// that was left alone; the SDK has no way to clear a preference, hence HIGH
/// only as a restore. Max is the exception: it asks for HIGH everywhere on purpose,
/// and its renderers report [maxQualityPixelDensity] so adaptive stream stays on.
///
/// Unsubscribed publications are skipped because LiveKit ignores a manual
/// setting on them and logs a warning instead; the session reapplies this on
/// every room event, so a track picks the choice up when it subscribes.
Future<void> applyReceiveVideoQuality(
  Iterable<RemoteVideoQualityRef> publications,
  ReceiveVideoQuality quality,
  Set<String> lowered,
) async {
  for (final pub in publications) {
    if (!pub.subscribed) continue;
    final screenShare = switch (pub.source) {
      lk.TrackSource.camera => false,
      lk.TrackSource.screenShareVideo => true,
      _ => null,
    };
    if (screenShare == null) continue;
    final layer = quality.layerFor(screenShare: screenShare);
    if (quality == ReceiveVideoQuality.max) {
      lowered.remove(pub.sid);
    } else if (layer == lk.VideoQuality.HIGH) {
      if (!lowered.remove(pub.sid)) continue;
    } else {
      lowered.add(pub.sid);
    }
    await pub.setQuality(layer);
  }
}

/// Every remote video publication of [room] as a [RemoteVideoQualityRef].
Iterable<RemoteVideoQualityRef> remoteVideoQualityRefs(lk.Room room) sync* {
  for (final participant in room.remoteParticipants.values) {
    for (final pub in participant.videoTrackPublications) {
      yield (
        sid: pub.sid,
        source: pub.source,
        subscribed: pub.subscribed,
        setQuality: pub.setVideoQuality,
      );
    }
  }
}

/// How sharp your own camera is published.
enum CameraQuality {
  /// 360p, for a weak upload.
  dataSaver(lk.VideoParametersPresets.h360_169),

  /// 720p, what a camera published before this setting existed.
  balanced(lk.VideoParametersPresets.h720_169),

  /// 1080p.
  high(lk.VideoParametersPresets.h1080_169);

  const CameraQuality(this.params);

  final lk.VideoParameters params;
}

/// [base] (the device and position a camera would have used anyway) with the
/// resolution and bitrate of [quality], so choosing a quality never forgets
/// which camera was picked.
lk.CameraCaptureOptions cameraCaptureOptionsFor(
  lk.CameraCaptureOptions base,
  CameraQuality quality,
) =>
    base.copyWith(params: quality.params);
