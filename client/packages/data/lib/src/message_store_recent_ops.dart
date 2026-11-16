// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The edits and deletes this process has applied, remembered so an older copy
/// of a message that arrives afterwards cannot undo them.
///
/// A copy can be older than what is stored: a frame held while a connect
/// catches up, or a page that was already on its way when the op landed. A
/// delete leaves no row to compare against and an edit keeps the same `seq`,
/// so neither is visible to a check on the row alone. In memory only, since
/// nothing in flight outlives the process that asked for it.
library;

/// A message's content as of its newest edit seen.
typedef SeenEdit = ({String content, int editedAt});

class RecentOps {
  RecentOps({this.capacity = 4096});

  /// How many of each kind are remembered before the oldest is forgotten.
  final int capacity;

  final _removed = <String>{};
  final _edits = <String, SeenEdit>{};

  /// Records that the server deleted [id].
  void removed(String id) {
    _edits.remove(id);
    _removed
      ..remove(id)
      ..add(id);
    if (_removed.length > capacity) _removed.remove(_removed.first);
  }

  bool isRemoved(String id) => _removed.contains(id);

  /// Records an edit of [id], keeping the newest when two are seen.
  void edited(String id, String content, int? editedAt) {
    if (editedAt == null) return;
    final known = _edits[id];
    if (known != null && known.editedAt > editedAt) return;
    _edits.remove(id);
    _edits[id] = (content: content, editedAt: editedAt);
    if (_edits.length > capacity) _edits.remove(_edits.keys.first);
  }

  /// The edit of [id] that is newer than a copy stamped [editedAt], if one was seen.
  SeenEdit? newerThan(String id, int? editedAt) {
    final known = _edits[id];
    if (known == null || known.editedAt <= (editedAt ?? 0)) return null;
    return known;
  }

  void clear() {
    _removed.clear();
    _edits.clear();
  }
}
