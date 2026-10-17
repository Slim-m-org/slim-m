// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'module_scene.dart';
import 'module_scene_painter.dart';

/// Actions waiting on the one module call in flight, oldest first.
///
/// A module call is a round trip and only one runs at a time, so a drag
/// across a grid produces actions faster than they can be sent. Dropping the
/// ones that arrive while busy would leave holes in a drawn line, so they
/// queue here and drain in order instead.
class SceneActionQueue {
  /// Capped so a long drag on a fine grid cannot build a backlog the board
  /// spends a minute catching up on. A dropped tail is better than a board
  /// that keeps moving after the finger stops.
  static const maxLength = 64;

  final _items = <String>[];

  /// Cells already sent during the current drag, so crossing one twice does
  /// not toggle it back off. Cleared when the drag starts.
  final _paintedThisDrag = <String>{};

  bool get isNotEmpty => _items.isNotEmpty;

  void clear() {
    _items.clear();
    _paintedThisDrag.clear();
  }

  void startDrag() => _paintedThisDrag.clear();

  /// Whether [action] is the first time this drag has sent it.
  bool markPainted(String action) => _paintedThisDrag.add(action);

  void add(String action) {
    if (_items.length >= maxLength) return;
    _items.add(action);
  }

  /// Puts a refused action back at the front so the line still finishes.
  void putBack(String action) => _items.insert(0, action);

  /// The next call to make: one queued action, or every leading action sharing
  /// a prefix the module reads as a list, joined into one.
  ///
  /// A whole drag becomes a single round trip that way. Without it the queue
  /// still drains in order and nothing is lost - it just costs a call per cell,
  /// which over a real network is what made drawing feel like work.
  String takeNext(ModuleScene scene) {
    final first = _items.removeAt(0);
    final prefix = first.split(':').first;
    if (!first.contains(':') || !sceneAllowsTapBatch(scene, first)) {
      return first;
    }
    final cells = <String>[first.substring(prefix.length + 1)];
    while (_items.isNotEmpty && _items.first.startsWith('$prefix:')) {
      cells.add(_items.removeAt(0).substring(prefix.length + 1));
    }
    return '$prefix:${cells.join(';')}';
  }
}
