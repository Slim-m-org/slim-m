// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How long since the person last touched any input on this machine, not just
/// this app, so working in another window still counts as being here.
///
/// Windows and macOS report it. Linux has no portable source (Wayland keeps
/// other apps' input private) and the web has none, so they return null and
/// callers fall back to input inside the app.
library;

import 'system_idle_stub.dart' if (dart.library.io) 'system_idle_io.dart'
    as impl;

abstract interface class SystemIdle {
  /// Time since the last keyboard or pointer input anywhere, or null when the
  /// host cannot say right now.
  Duration? idleTime();
}

/// The host's source, or null where there is none.
SystemIdle? createSystemIdle() => impl.createSystemIdle();
