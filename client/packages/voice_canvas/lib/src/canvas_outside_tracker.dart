// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which live objects the board cannot hold whole, and how many.
library;

import 'package:flutter/foundation.dart';

class CanvasOutsideTracker {
  final Set<String> _ids = {};

  /// How many live objects the board cannot hold whole.
  final ValueNotifier<int> count = ValueNotifier<int>(0);

  List<String> get ids => List.unmodifiable(_ids);

  bool contains(String id) => _ids.contains(id);

  /// Records whether [id] now sits outside the board.
  void mark(String id, {required bool outside}) {
    final changed = outside ? _ids.add(id) : _ids.remove(id);
    if (changed) count.value = _ids.length;
  }

  void forget(String id) => mark(id, outside: false);

  void clear() {
    _ids.clear();
    count.value = 0;
  }

  void dispose() => count.dispose();
}
