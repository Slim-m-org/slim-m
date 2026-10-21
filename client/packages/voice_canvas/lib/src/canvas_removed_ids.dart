// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The bounded set of ids a canvas document was told to drop.
library;

import 'dart:collection';

import 'canvas_stroke.dart';

/// Ids the server told the document to drop, so a viewport read in flight during the removal cannot resurrect them.
/// Each remembers its removal's op seq when known, so a later snapshot can restore it; eviction is FIFO at [maxRemovedIdsTracked].
class RemovedIds {
  final LinkedHashMap<String, int?> _seqs = LinkedHashMap<String, int?>();

  bool contains(String id) => _seqs.containsKey(id);

  /// The seq of the op that removed [id], or null while that is not known.
  int? seqOf(String id) => _seqs[id];

  /// Remembers [id]; a known [seq] replaces an unknown one.
  void add(String id, {int? seq}) {
    if (_seqs.containsKey(id)) {
      if (seq != null) _seqs[id] = seq;
      return;
    }
    _seqs[id] = seq;
    if (_seqs.length > maxRemovedIdsTracked) _seqs.remove(_seqs.keys.first);
  }

  /// Records [seq] for those of [ids] still waiting on one.
  void confirm(Iterable<String> ids, int seq) {
    for (final id in ids) {
      if (_seqs.containsKey(id) && _seqs[id] == null) _seqs[id] = seq;
    }
  }

  void removeAll(Set<String> ids) => ids.forEach(_seqs.remove);

  void clear() => _seqs.clear();
}
