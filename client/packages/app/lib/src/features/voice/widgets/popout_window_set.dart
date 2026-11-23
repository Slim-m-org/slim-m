// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The open pop-out windows, one per feed key.
///
/// Creating a native window can run Dart re-entrantly: Windows pumps the
/// event loop while it sizes the new view. A sync asked for during another is
/// therefore folded into a rerun once the first is done, rather than opening a
/// second window for a key whose first is still being created.
library;

class PopOutWindowSet<F, W> {
  PopOutWindowSet({required this.open, required this.close});

  /// Opens the window for a feed, or null where none can be opened.
  final W? Function(F feed) open;

  /// Destroys a window that is no longer wanted or has been superseded.
  final void Function(W window) close;

  final _windows = <String, W>{};
  bool _syncing = false;
  Map<String, F>? _rerun;

  Iterable<MapEntry<String, W>> get entries => _windows.entries;
  Iterable<W> get windows => _windows.values;
  bool get isEmpty => _windows.isEmpty;

  /// Opens a window for each wanted key that has none and closes the rest.
  void sync(Map<String, F> wanted) {
    if (_syncing) {
      _rerun = wanted;
      return;
    }
    _syncing = true;
    try {
      for (final key in _windows.keys.toList()) {
        if (!wanted.containsKey(key)) close(_windows.remove(key) as W);
      }
      for (final MapEntry(:key, value: feed) in wanted.entries) {
        if (_windows.containsKey(key)) continue;
        final window = open(feed);
        if (window != null) adopt(key, window);
      }
    } catch (_) {
      _rerun = null;
      rethrow;
    } finally {
      _syncing = false;
    }
    final rerun = _rerun;
    _rerun = null;
    if (rerun != null) sync(rerun);
  }

  /// Keeps [window] for [key], closing any window it supersedes.
  void adopt(String key, W window) {
    final previous = _windows[key];
    _windows[key] = window;
    if (previous != null && !identical(previous, window)) close(previous);
  }

  void closeAll() {
    final all = _windows.values.toList();
    _windows.clear();
    all.forEach(close);
  }
}
