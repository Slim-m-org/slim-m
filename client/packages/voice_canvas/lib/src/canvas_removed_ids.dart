// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The bounded set of ids a canvas document was told to drop.
library;

import 'dart:collection';

import 'canvas_stroke.dart';

/// Ids the server told the document to drop, so a viewport read still in
/// flight when the removal landed cannot resurrect them.
///
/// Eviction is FIFO once [maxRemovedIdsTracked] is reached, since no read in
/// flight can name more live ids than the channel's own ceiling.
class RemovedIds {
  final Set<String> _ids = <String>{};
  final Queue<String> _order = Queue<String>();

  bool contains(String id) => _ids.contains(id);

  /// Remembers [id]; a no-op for one already held.
  void add(String id) {
    if (!_ids.add(id)) return;
    _order.add(id);
    if (_order.length > maxRemovedIdsTracked) {
      _ids.remove(_order.removeFirst());
    }
  }

  void removeAll(Set<String> ids) {
    _ids.removeAll(ids);
    _order.removeWhere(ids.contains);
  }

  void clear() {
    _ids.clear();
    _order.clear();
  }
}
