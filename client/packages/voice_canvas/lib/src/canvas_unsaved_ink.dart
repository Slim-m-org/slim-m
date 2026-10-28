// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which of the viewer's own strokes the server has not accepted yet because the save is being retried.
/// The painter draws them faded, so ink that would be lost on a refresh looks different from ink that is safe.
library;

import 'package:flutter/foundation.dart';

class UnsavedInk {
  final Set<String> _ids = {};

  /// How many strokes are waiting on a retry, for the pane's hint.
  final ValueNotifier<int> count = ValueNotifier<int>(0);

  bool contains(String id) => _ids.contains(id);

  /// Returns whether the set changed, so the owner knows whether to repaint.
  bool set(String id, {required bool unsaved}) {
    final changed = unsaved ? _ids.add(id) : _ids.remove(id);
    if (changed) count.value = _ids.length;
    return changed;
  }

  void clear() {
    _ids.clear();
    count.value = 0;
  }

  void dispose() => count.dispose();
}
