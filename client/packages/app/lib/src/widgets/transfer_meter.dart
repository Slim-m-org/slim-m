// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How fast an upload is going and how long it has left, smoothed so the
/// estimate does not jump with every progress callback.
library;

import 'dart:math' as math;

/// Uploads shorter than this show no speed or estimate: there is nothing to wait for.
const Duration kTransferDetailAfter = Duration(seconds: 10);

class TransferMeter {
  TransferMeter([DateTime Function()? clock])
    : _clock = clock ?? DateTime.now,
      startedAt = (clock ?? DateTime.now)();

  final DateTime Function() _clock;
  final DateTime startedAt;

  /// How quickly the smoothed rate follows a change, in seconds.
  static const double _smoothing = 3;

  /// Samples closer together than this are folded into the next one.
  static const Duration _minGap = Duration(milliseconds: 250);

  DateTime? _lastAt;
  int _lastBytes = 0;
  double? _rate;

  void record(int sent) {
    final at = _clock();
    final lastAt = _lastAt;
    if (lastAt == null || sent < _lastBytes) {
      // A resume can restart from the server's offset; measure from there.
      _lastAt = at;
      _lastBytes = sent;
      return;
    }
    final gap = at.difference(lastAt);
    if (gap < _minGap) return;
    final seconds = gap.inMicroseconds / Duration.microsecondsPerSecond;
    final instant = (sent - _lastBytes) / seconds;
    final rate = _rate;
    final weight = 1 - math.exp(-seconds / _smoothing);
    _rate = rate == null ? instant : rate + weight * (instant - rate);
    _lastAt = at;
    _lastBytes = sent;
  }

  /// Bytes a second, or null while nothing has been measured or nothing moves.
  double? get bytesPerSecond {
    final rate = _rate;
    return rate != null && rate > 0 && rate.isFinite ? rate : null;
  }

  /// Time left at the current rate, or null when the rate is unknown.
  Duration? remaining(int sent, int total) {
    final rate = bytesPerSecond;
    if (rate == null) return null;
    final seconds = math.max(0, total - sent) / rate;
    return Duration(seconds: math.min(seconds, 99 * 3600).ceil());
  }

  /// Whether the upload has run long enough to be worth an estimate.
  bool get showsDetail =>
      _clock().difference(startedAt) >= kTransferDetailAfter &&
      bytesPerSecond != null;
}

/// "about 40 s left", "about 7 min left", "about 2 h left".
String formatTimeLeft(Duration left) {
  if (left.inSeconds < 60) return 'about ${math.max(1, left.inSeconds)} s left';
  if (left.inMinutes < 60) {
    return 'about ${(left.inSeconds / 60).ceil()} min left';
  }
  final hours = left.inMinutes / 60;
  return 'about ${hours < 10 ? hours.toStringAsFixed(1) : hours.round()} h left';
}
