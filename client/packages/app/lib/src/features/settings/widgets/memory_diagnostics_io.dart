// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The `dart:io` side of the resident-size read; see the web sibling for why
/// this is split behind a conditional import.
library;

import 'dart:io';

/// The process's current resident set size in bytes, or null if the platform
/// does not report it. `dart:io`'s [ProcessInfo.currentRss] answers on the VM
/// (desktop and mobile) and is what a task manager's memory column shows.
int? currentResidentBytes() {
  try {
    return ProcessInfo.currentRss;
  } catch (_) {
    return null;
  }
}
