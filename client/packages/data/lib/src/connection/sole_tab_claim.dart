// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';

/// The slice of the browser's lock manager a sole-tab claim needs.
abstract interface class TabLockManager {
  /// Reports whether the named lock was granted; a granted lock is held until
  /// the tab closes. A rejected request reports through [onError].
  void requestIfAvailable(
    String name,
    void Function(bool granted) onResult,
    void Function(Object error) onError,
  );
}

/// Claims the lock for one database; false when held already or when the
/// request fails, so a tab that cannot lock never sweeps another tab's sends.
Future<bool> claimSoleTabWith(TabLockManager? locks, String database) {
  if (locks == null) return Future.value(true);
  final claim = Completer<bool>();
  locks.requestIfAvailable(
    'slimm-sole-tab:$database',
    (granted) {
      if (!claim.isCompleted) claim.complete(granted);
    },
    (_) {
      if (!claim.isCompleted) claim.complete(false);
    },
  );
  return claim.future;
}
