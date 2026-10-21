// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The z-sorted, culled slot list a canvas painter walks each frame.
library;

/// Caches every alive slot sorted by paint order and filters it to the slots a cull kept; a pan or zoom never changes relative order, so it re-sorts only after [markDirty].
class PaintOrderCache {
  final List<int> _sortedAlive = <int>[];
  final List<int> _order = <int>[];
  bool _dirty = true;

  /// Whether slot `i` was in the cull the last [order] filtered against, so
  /// the filter is one array lookup per candidate. [_markedSlots] lets the next
  /// call clear only the slots this one set.
  final List<bool> _visibleMark = <bool>[];
  final List<int> _markedSlots = <int>[];

  /// Call when slot membership or any `zIndex` changed.
  void markDirty() => _dirty = true;

  /// Forgets every slot, as a hard reset of the document does.
  void clear() {
    _order.clear();
    _sortedAlive.clear();
    _dirty = false;
    _visibleMark.clear();
    _markedSlots.clear();
  }

  /// [visible] slots in paint order, bottom first.
  /// Sorted here because the grid answers in cell order on one branch and slot order on the other, so painting the raw cull would re-layer overlapping ink across the adaptive threshold; the returned list is reused.
  List<int> order({
    required int slotCount,
    required bool Function(int slot) isAlive,
    required int Function(int a, int b) compare,
    required Iterable<int> visible,
  }) {
    if (_dirty) _resortAlive(slotCount, isAlive, compare);
    _markVisible(visible);
    _order
      ..clear()
      ..addAll(
        _sortedAlive.where(
          (slot) => slot < _visibleMark.length && _visibleMark[slot],
        ),
      );
    return _order;
  }

  void _resortAlive(
    int slotCount,
    bool Function(int slot) isAlive,
    int Function(int a, int b) compare,
  ) {
    _sortedAlive
      ..clear()
      ..addAll([
        for (var slot = 0; slot < slotCount; slot++)
          if (isAlive(slot)) slot,
      ]);
    _sortedAlive.sort(compare);
    _dirty = false;
  }

  void _markVisible(Iterable<int> visible) {
    for (final slot in _markedSlots) {
      _visibleMark[slot] = false;
    }
    _markedSlots.clear();
    for (final slot in visible) {
      while (_visibleMark.length <= slot) {
        _visibleMark.add(false);
      }
      _visibleMark[slot] = true;
      _markedSlots.add(slot);
    }
  }
}
