// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keeps a dragged slider from flooding the platform channel.
library;

import 'dart:async';

const Duration kVolumeDragInterval = Duration(milliseconds: 60);

/// Applies the first value at once, then at most one value per [interval],
/// and always the newest one last.
class TrailingThrottle<T> {
  TrailingThrottle(
    this._apply, {
    this.interval = kVolumeDragInterval,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Future<void> Function(T value) _apply;
  final Duration interval;
  final DateTime Function() _now;

  DateTime? _lastApplied;
  Timer? _timer;
  T? _pending;

  Future<void> push(T value) {
    final last = _lastApplied;
    final since = last == null ? interval : _now().difference(last);
    if (_timer == null && since >= interval) return _run(value);
    _pending = value;
    final wait = interval - since;
    _timer ??= Timer(wait.isNegative ? Duration.zero : wait, _fire);
    return Future.value();
  }

  /// Drops a value still waiting, for a caller about to apply a final one.
  void cancel() {
    _timer?.cancel();
    _timer = null;
    _pending = null;
  }

  void _fire() {
    _timer = null;
    final value = _pending;
    _pending = null;
    if (value != null) unawaited(_run(value));
  }

  Future<void> _run(T value) {
    _lastApplied = _now();
    return _apply(value);
  }
}
