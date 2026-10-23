// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Coordination between browser tabs that share one stored session.
///
/// Native platforms have one process per session, so they get a no-op.
library;

import 'cross_tab_io.dart' if (dart.library.js_interop) 'cross_tab_web.dart'
    as impl;

abstract interface class CrossTab {
  /// The tabs of this browser profile.
  factory CrossTab() => impl.createCrossTab();

  /// Runs [body] under a lock named [name] that every tab shares.
  Future<T> exclusive<T>(String name, Future<T> Function() body);

  /// Fires when another tab wrote to browser storage.
  Stream<void> get storageChanges;
}
