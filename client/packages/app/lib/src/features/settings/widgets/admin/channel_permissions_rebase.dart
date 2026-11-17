// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Carries a grid's unsaved edits onto rows someone else just rewrote.
library;

/// Takes [fresh] into [pending] and [removed] for every row the local admin
/// has not edited, and rebases the ones they have.
void mergeRemoteRows({
  required Map<String, (int, int)> original,
  required Map<String, (int, int)> pending,
  required Set<String> removed,
  required Map<String, (int, int)> fresh,
}) {
  for (final key in {...original.keys, ...fresh.keys}) {
    final mine = pending[key];
    final edited =
        removed.contains(key) || (mine != null && mine != original[key]);
    if (!edited) {
      if (fresh[key] case final row?) {
        pending[key] = row;
      } else {
        pending.remove(key);
      }
    } else if (fresh[key] case final row?) {
      if (mine != null) {
        pending[key] = rebasePending(
          original: original[key] ?? (0, 0),
          pending: mine,
          fresh: row,
        );
      }
    } else {
      removed.remove(key);
    }
  }
}

/// [pending] with every bit the local edit left alone taken from [fresh].
///
/// A bit counts as edited when its allow or deny differs from [original].
(int, int) rebasePending({
  required (int, int) original,
  required (int, int) pending,
  required (int, int) fresh,
}) {
  final edited = (pending.$1 ^ original.$1) | (pending.$2 ^ original.$2);
  return (
    (pending.$1 & edited) | (fresh.$1 & ~edited),
    (pending.$2 & edited) | (fresh.$2 & ~edited),
  );
}
