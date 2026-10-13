// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The two things a caller has to say and be told about a screen share: how
/// it may be published, and what asking actually did.
///
/// Split out of `voice_session.dart` because neither depends on a session or
/// on LiveKit, and both are read by the UI far from any call.
library;

/// The capture resolution of a screen share.
enum ScreenShareResolution {
  p720(width: 1280, height: 720),
  p1080(width: 1920, height: 1080),
  p1440(width: 2560, height: 1440);

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

  // Bits per second by [resolution.index][frameRate.index].
  static const _maxBitrates = [
    [1000000, 1500000, 2500000],
    [1600000, 2400000, 4000000],
    [3000000, 3600000, 5000000],
  ];

  final ScreenShareResolution resolution;
  final ScreenShareFps frameRate;

  int get width => resolution.width;
  int get height => resolution.height;
  int get fps => frameRate.value;
  int get maxBitrate => _maxBitrates[resolution.index][frameRate.index];

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

/// A screen the OS will let this app capture.
///
/// Screens only, never windows. Enumerating windows through libwebrtc's
/// desktop capturer segfaults the process on Fedora Wayland (SIGSEGV, exit
/// 139, reproduced 2026-07-27), and a native crash is not catchable from Dart.
class ScreenShareSource {
  const ScreenShareSource({required this.id, required this.name});

  /// Opaque to us, and the only thing `getDisplayMedia` matches on.
  final String id;

  /// The capturer's own label, 'Screen 1' and up on Linux.
  final String name;
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
