// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Judges from the sender's own stats whether a screen share still carries a
/// live picture, because Windows window capture goes silent without saying so.
library;

/// What the sender's outbound stats say about the share at one sample.
class ShareReading {
  const ShareReading({this.framesSent, this.width, this.height});

  /// Frames sent so far, summed over the simulcast layers; null when the platform reports none.
  final int? framesSent;
  final int? width;
  final int? height;
}

enum ShareLiveness {
  /// Not enough readings yet to say.
  unknown,

  /// Frames are leaving the capturer at a real size.
  live,

  /// Looks wrong, but not for long enough to act on.
  suspect,

  /// Wrong for [ShareLivenessWatch.freezeAfter]: the picture receivers see is stale.
  frozen,
}

/// A window capturer emits on every tick, so a window share whose frame count
/// stands still has lost its source (minimized, hidden, mid fullscreen switch).
/// A whole screen may legitimately emit nothing while it is static, so only a
/// collapsed frame size counts against it.
class ShareLivenessWatch {
  ShareLivenessWatch({
    this.freezeAfter = const Duration(seconds: 6),
    this.minProgressFrames = 2,
    this.tinyPixels = 256,
  });

  final Duration freezeAfter;

  /// Frames between two readings that count as the capturer running.
  final int minProgressFrames;

  /// A frame this small is the stand-in a capturer sends for a source it cannot see.
  final int tinyPixels;

  int? _lastFrames;
  DateTime? _badSince;
  ShareLiveness _verdict = ShareLiveness.unknown;

  ShareLiveness get verdict => _verdict;

  /// Forgets what came before; a restarted capture starts its counters again.
  void reset() {
    _lastFrames = null;
    _badSince = null;
    _verdict = ShareLiveness.unknown;
  }

  ShareLiveness observe(
    ShareReading reading, {
    required bool windowShare,
    required DateTime now,
  }) {
    final frames = reading.framesSent;
    final last = _lastFrames;
    _lastFrames = frames;
    final width = reading.width;
    final height = reading.height;
    final tiny =
        width != null && height != null && width * height <= tinyPixels;
    final progressed =
        frames != null && last != null && frames - last >= minProgressFrames;
    final judgeable = frames != null && last != null;
    final stood = windowShare && judgeable && !progressed;
    if (!tiny && !stood) {
      _badSince = null;
      final flowing = windowShare ? progressed : width != null && !tiny;
      return _verdict = flowing ? ShareLiveness.live : ShareLiveness.unknown;
    }
    final since = _badSince ??= now;
    return _verdict = now.difference(since) >= freezeAfter
        ? ShareLiveness.frozen
        : ShareLiveness.suspect;
  }
}
