// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The two things a caller has to say and be told about a screen share: how
/// it may be published, and what asking actually did.
///
/// Split out of `voice_session.dart` because neither depends on a session or
/// on LiveKit, and both are read by the UI far from any call.
library;

import 'package:flutter/foundation.dart' show visibleForTesting;

/// The capture resolution of a screen share.
enum ScreenShareResolution {
  p720(width: 1280, height: 720),
  p1080(width: 1920, height: 1080),
  p1440(width: 2560, height: 1440),
  p2160(width: 3840, height: 2160);

  const ScreenShareResolution({required this.width, required this.height});

  final int width;
  final int height;

  String get label => '${height}p';
}

/// The capture frame rate of a screen share.
enum ScreenShareFps {
  fps15(15, '15 fps'),
  fps30(30, '30 fps'),
  fps60(60, '60 fps');

  const ScreenShareFps(this.value, this.label);

  final int value;
  final String label;
}

/// How a screen share is published: a resolution and a frame rate, with the
/// bitrate ceiling derived from the pair (see docs/video-quality.md).
///
/// Ceilings rather than preferences: an unbounded share on a 4K monitor will
/// happily saturate a home upload and starve the audio it is supposed to
/// accompany, and audio degrading is far more noticeable than a slightly softer
/// screen.
class ScreenShareQuality {
  const ScreenShareQuality(this.resolution, this.frameRate);

  /// What a share published before the two choices were separate.
  static const standard = ScreenShareQuality(
    ScreenShareResolution.p1080,
    ScreenShareFps.fps30,
  );

  /// Every pair, resolution-major.
  static final all = [
    for (final r in ScreenShareResolution.values)
      for (final f in ScreenShareFps.values) ScreenShareQuality(r, f),
  ];

  /// Bits per second by [resolution.index][frameRate.index].
  ///
  /// Anchored on LiveKit's own 720p30 = 2 Mbps and 1080p30 = 5 Mbps; see
  /// docs/video-quality.md for how the other cells scale from them.
  @visibleForTesting
  static const bitrateTable = [
    [1500000, 2000000, 3200000],
    [2500000, 5000000, 8000000],
    [4000000, 7500000, 12000000],
    [6000000, 10000000, 12000000],
  ];

  /// The most any tier may publish, so a 4K share cannot starve call audio.
  static const bitrateCeiling = 12000000;

  final ScreenShareResolution resolution;
  final ScreenShareFps frameRate;

  int get width => resolution.width;
  int get height => resolution.height;
  int get fps => frameRate.value;
  int get maxBitrate => bitrateTable[resolution.index][frameRate.index];

  /// The stored form, such as `1080p30`.
  String get id => '${resolution.height}p${frameRate.value}';

  /// The pair [id] names, or null when it names none.
  static ScreenShareQuality? fromId(String? id) {
    for (final q in all) {
      if (q.id == id) return q;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is ScreenShareQuality &&
      other.resolution == resolution &&
      other.frameRate == frameRate;

  @override
  int get hashCode => Object.hash(resolution, frameRate);

  @override
  String toString() => 'ScreenShareQuality($id)';
}

/// What a share is really published at once the captured source is known.
class ScreenShareFit {
  const ScreenShareFit({
    required this.quality,
    required this.width,
    required this.height,
  });

  /// The tier whose bitrate and frame rate apply to [width] by [height].
  final ScreenShareQuality quality;
  final int width;
  final int height;
}

/// Never publishes above the shared source or the space ceiling.
///
/// A 1080p screen with the 2160p tier picked would otherwise hand the encoder
/// a 3840x2160 layout and a 12 Mbps top layer it can never fill.
ScreenShareFit fitScreenShare(
  ScreenShareQuality chosen, {
  required int sourceWidth,
  required int sourceHeight,
  int? maxHeight,
}) {
  final limit =
      [chosen.height, sourceHeight, if (maxHeight != null) maxHeight].reduce(
    (a, b) => a < b ? a : b,
  );
  final tier = ScreenShareResolution.values.lastWhere(
    (r) => r.height <= limit,
    orElse: () => ScreenShareResolution.values.first,
  );
  final quality = ScreenShareQuality(tier, chosen.frameRate);
  return ScreenShareFit(
    quality: quality,
    width: quality.width < sourceWidth ? quality.width : sourceWidth,
    height: quality.height < sourceHeight ? quality.height : sourceHeight,
  );
}

/// A screen the OS will let this app capture.
///
/// A screen, or on Windows and macOS a window. Linux lists screens only:
/// enumerating windows through libwebrtc's desktop capturer segfaults the
/// process on Fedora Wayland (SIGSEGV, exit 139, reproduced 2026-07-27), a
/// native crash Dart cannot catch, and the portal's own picker chooses there.
class ScreenShareSource {
  const ScreenShareSource({
    required this.id,
    required this.name,
    this.isWindow = false,
  });

  /// Opaque to us, and the only thing `getDisplayMedia` matches on.
  final String id;

  /// The capturer's own label, 'Screen 1' and up on Linux.
  final String name;

  /// A single window rather than a whole screen.
  final bool isWindow;
}

/// What asking to share a screen actually did.
///
/// Deliberately not a bool. On iOS "the request went through" and "somebody
/// can see a screen" are two different moments with a user in between: capture
/// runs in a broadcast upload extension that only the system picker can start.
/// A bool has to pick one of those to mean, and either choice makes the button
/// lie in one direction. See [BroadcastBridge] for why the platform is like
/// this.
enum ScreenShareOutcome {
  /// A screen track is published. Everyone in the call can see it now.
  started,

  /// The request went through, nothing is published yet, and it is up to the
  /// user: iOS has been asked to show its broadcast picker. If they dismiss
  /// it, nothing further happens and no failure is reported anywhere.
  pendingBroadcast,

  /// This build cannot share a screen at all, because it has no working
  /// broadcast extension. Asking again will not help.
  unsupported,

  /// Sharing is off, as asked.
  stopped,

  /// The request failed outright. [VoiceSession.lastError] says how.
  failed,
}
