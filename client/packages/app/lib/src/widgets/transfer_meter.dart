// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How fast an upload or download is going and how long it has left, smoothed
/// so the estimate does not jump with every progress callback.
library;

import 'dart:math' as math;

import '../features/messages/widgets/attachment_format.dart';

/// The estimate is hidden until the meter has measured for this long, so the first noisy seconds never reach the screen.
const Duration kTransferDetailAfter = Duration(seconds: 2);

/// With no bytes for longer than this the shown rate decays, so a stalled transfer stops promising its old finish time.
const Duration _stallAfter = Duration(seconds: 2);

class TransferMeter {
  TransferMeter([DateTime Function()? clock])
    : _clock = clock ?? DateTime.now,
      _measuredSince = (clock ?? DateTime.now)();

  final DateTime Function() _clock;
  DateTime _measuredSince;

  /// How quickly the smoothed rate follows a change, in seconds.
  static const double _smoothing = 3;

  /// Samples closer together than this are folded into the next one.
  static const Duration _minGap = Duration(milliseconds: 250);

  DateTime? _lastAt;
  int _lastBytes = 0;
  double? _rate;

  /// Forgets the measured rate, for a reconnect: the old speed says nothing about the new link.
  void reset() {
    _lastAt = null;
    _lastBytes = 0;
    _rate = null;
    _measuredSince = _clock();
  }

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
    final lastAt = _lastAt;
    if (rate == null || lastAt == null || rate <= 0 || !rate.isFinite) {
      return null;
    }
    final idle = _clock().difference(lastAt) - _stallAfter;
    if (idle <= Duration.zero) return rate;
    final seconds = idle.inMicroseconds / Duration.microsecondsPerSecond;
    return rate * math.exp(-seconds / _smoothing);
  }

  /// Time left at the current rate, or null when the rate is unknown.
  Duration? remaining(int sent, int total) {
    final rate = bytesPerSecond;
    if (rate == null) return null;
    final seconds = math.max(0, total - sent) / rate;
    return Duration(seconds: math.min(seconds, 99 * 3600).ceil());
  }

  /// Whether the transfer has been measured long enough to be worth an estimate.
  bool get showsDetail =>
      _clock().difference(_measuredSince) >= kTransferDetailAfter &&
      bytesPerSecond != null;
}

/// "40 s left", "7 min left", "2 h left".
String formatTimeLeft(Duration left) {
  if (left.inSeconds < 60) return '${math.max(1, left.inSeconds)} s left';
  if (left.inMinutes < 60) return '${(left.inSeconds / 60).ceil()} min left';
  final hours = left.inMinutes / 60;
  return '${hours < 10 ? hours.toStringAsFixed(1) : hours.round()} h left';
}

/// "38.0 MB/s".
String formatTransferRate(double bytesPerSecond) =>
    '${formatByteSize(bytesPerSecond.round())}/s';

/// "42% · 38.0 MB/s · 2 min left" once the [meter] has an estimate, else the
/// plain "42% of 5.4 GB" (or just "42%" when the total is unknown).
String formatTransferLine({
  required int sent,
  required int? total,
  required TransferMeter? meter,
  bool reconnecting = false,
}) {
  final percent = total == null || total <= 0
      ? null
      : (sent / total * 100).clamp(0, 100).floor();
  if (reconnecting) return 'Reconnecting at ${percent ?? 0}%…';
  final rate = meter?.bytesPerSecond;
  final left = total == null ? null : meter?.remaining(sent, total);
  if (meter != null && meter.showsDetail && rate != null) {
    return [
      percent == null ? formatByteSize(sent) : '$percent%',
      formatTransferRate(rate),
      ?left == null ? null : formatTimeLeft(left),
    ].join(' · ');
  }
  if (percent == null) return formatByteSize(sent);
  return '$percent% of ${formatByteSize(total!)}';
}
