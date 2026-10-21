// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How long since the person last touched any input on this machine, so working in another window counts as being here.
/// Windows and macOS report it; Linux (Wayland keeps input private) and web return null and callers fall back to in-app input.
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
