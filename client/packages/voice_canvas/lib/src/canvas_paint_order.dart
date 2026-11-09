// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The z-sorted, culled slot list a canvas painter walks each frame.
library;

/// How many queued edits are cheaper to apply one by one than by re-sorting everything.
const int _maxQueuedEdits = 64;

/// Caches every alive slot sorted by paint order and filters it to the slots a cull kept; a pan or zoom never changes relative order, so it re-sorts only after [markDirty].
/// A few [added], [removed] or [reordered] slots are spliced into the sorted list instead of re-sorting it.
class PaintOrderCache {
  final List<int> _sortedAlive = <int>[];
  final List<int> _order = <int>[];
  final Set<int> _gone = <int>{};
  final Set<int> _arrived = <int>{};
  bool _dirty = true;

  /// Whether slot `i` was in the cull the last [order] filtered against, so
  /// the filter is one array lookup per candidate. [_markedSlots] lets the next
  /// call clear only the slots this one set.
  final List<bool> _visibleMark = <bool>[];
  final List<int> _markedSlots = <int>[];

  /// Call when slot membership or the sort key of many slots changed.
  void markDirty() {
    _dirty = true;
    _gone.clear();
    _arrived.clear();
  }

  /// A new alive [slot] that was in no earlier order.
  void added(int slot) {
    if (_dirty) return;
    _arrived.add(slot);
    _limitQueue();
  }

  /// A [slot] that is no longer alive or no longer exists.
  void removed(int slot) {
    if (_dirty) return;
    _gone.add(slot);
    _limitQueue();
  }

  /// A [slot] whose sort key changed, or that came back to life.
  void reordered(int slot) {
    if (_dirty) return;
    _gone.add(slot);
    _arrived.add(slot);
    _limitQueue();
  }

  void _limitQueue() {
    if (_gone.length + _arrived.length > _maxQueuedEdits) markDirty();
  }

  /// Forgets every slot, as a hard reset of the document does.
  void clear() {
    _order.clear();
    _sortedAlive.clear();
    _gone.clear();
    _arrived.clear();
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
    if (_dirty) {
      _resortAlive(slotCount, isAlive, compare);
    } else {
      _applyEdits(isAlive, compare);
    }
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

  void _applyEdits(
      bool Function(int slot) isAlive, int Function(int a, int b) compare) {
    _gone.forEach(_sortedAlive.remove);
    for (final slot in _arrived) {
      if (isAlive(slot)) _insert(slot, compare);
    }
    _gone.clear();
    _arrived.clear();
  }

  void _insert(int slot, int Function(int a, int b) compare) {
    if (_sortedAlive.isEmpty || compare(_sortedAlive.last, slot) < 0) {
      _sortedAlive.add(slot);
      return;
    }
    var low = 0;
    var high = _sortedAlive.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (compare(_sortedAlive[mid], slot) < 0) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    _sortedAlive.insert(low, slot);
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
