// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether this is the only live copy of the app on the local database.
///
/// A browser shares one database across every tab of the origin, so a send
/// another tab has in flight looks the same as one a dead run left behind.
/// Only the tab that wins the lock may treat pending rows as abandoned.
library;

export 'sole_tab_native.dart' if (dart.library.js_interop) 'sole_tab_web.dart';
