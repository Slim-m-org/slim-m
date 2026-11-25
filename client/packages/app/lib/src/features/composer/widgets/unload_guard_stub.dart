// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The non-web half of `unload_guard.dart`: nothing to confirm outside a tab.
library;

/// Marks [owner] as holding work a tab close would lose, or as done.
void guardUnload(Object owner, {required bool active}) {}
