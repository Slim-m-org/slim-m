// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

/// Lets one frame type ask for a resync only once per [every].
///
/// A frame shape this client cannot read arrives again with the next message, and a reconnect per message never catches up.
class ParseResyncThrottle {
  ParseResyncThrottle({
    this.every = const Duration(seconds: 30),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration every;
  final DateTime Function() _now;
  final _last = <String, DateTime>{};

  bool allow(String frameType) {
    final now = _now();
    final last = _last[frameType];
    if (last != null && now.difference(last) < every) return false;
    _last[frameType] = now;
    return true;
  }
}
