// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A native player that exists only while something is playing on it, so a
/// finished ring or hold loop does not keep an audio session allocated.
library;

class ReleasablePlayer<T> {
  ReleasablePlayer(this._create, this._dispose);

  final T Function() _create;
  final Future<void> Function(T player) _dispose;
  T? _player;

  /// Whether a native player is currently allocated.
  bool get allocated => _player != null;

  /// The player, built on first use after a [release].
  T get current => _player ??= _create();

  /// Disposes the player; the next [current] builds a fresh one.
  Future<void> release() async {
    final player = _player;
    _player = null;
    if (player != null) await _dispose(player);
  }
}
