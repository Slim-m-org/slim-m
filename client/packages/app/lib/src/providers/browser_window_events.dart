// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A browser tab's window focus as the same events a desktop window raises.
///
/// A visible tab on a second monitor is still `resumed` to Flutter while the
/// person works in another window, so only the window's own blur and focus say
/// whether anyone is looking at it.
library;

export 'browser_window_events_stub.dart'
    if (dart.library.js_interop) 'browser_window_events_web.dart';
