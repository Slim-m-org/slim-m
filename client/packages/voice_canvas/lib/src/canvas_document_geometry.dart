// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'canvas_document.dart';

/// Where a live object sits and how it moves, on [CanvasDocument].
extension CanvasDocumentGeometry on CanvasDocument {
  /// Every live object drawn as one mark with [id] - [id] itself when it
  /// was never split - in no particular order.
  List<String> groupOf(String id) {
    final slot = _slotById[id];
    final group = slot == null ? null : _strokes[slot]?.groupId;
    if (group == null) return [id];
    return [
      for (final member in _slotsByGroup[group] ?? const <int>[])
        if (_strokes[member] case final stroke? when stroke.alive) stroke.id,
    ];
  }

  /// The bounds a live object currently occupies, or null if [id] is unknown
  /// or has been removed. What [moveObject]'s caller needs to compute a drag
  /// delta, and what an undo needs to restore a move's own original box.
  ({double x, double y, double w, double h})? objectBounds(String id) {
    final slot = _slotById[id];
    final stroke = slot == null ? null : _strokes[slot];
    if (stroke == null || !stroke.alive) return null;
    return (x: stroke.x, y: stroke.y, w: stroke.w, h: stroke.h);
  }

  /// Repositions a live object to a new box in place, so a moved stroke still hit-tests against its drawn shape; false if [id] is unknown or removed.
  /// Called per pointer event during a drag, so [UniformGrid.move] keeps the slot and points shift in place: free-and-reinsert leaked a grid slot per event and allocated a stroke, `Float32List` and [Path] each time.
  /// The box is applied as given; a gesture holds it to the board with [boxOnBoard] first, so undo, rollback or a remote move can place an object where the server has it.
  bool moveObject(String id, double x, double y, double w, double h) {
    final slot = _slotById[id];
    if (slot == null) return false;
    final stroke = _strokes[slot];
    if (stroke == null || !stroke.alive) return false;
    final dx = x - stroke.x;
    final dy = y - stroke.y;
    if (dx == 0 && dy == 0 && w == stroke.w && h == stroke.h) return true;
    final points = stroke.points;
    for (var i = 0; i < points.length; i++) {
      points[i] += i.isEven ? dx : dy;
    }
    scene.move(slot, x, y, x + w, y + h);
    stroke
      ..x = x
      ..y = y
      ..w = w
      ..h = h;
    if (_board != null) _trackOutside(stroke);
    // The dragged object paints live above the cached ink, so its own moves leave the cache valid.
    if (elevatedObjectId.value != id) _changed();
    return true;
  }
}
