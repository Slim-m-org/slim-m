// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Starting the desktop app when the user signs in to their computer.
///
/// The registration lives with the operating system, so [Autostart.isEnabled]
/// reads it back each time rather than trusting a stored preference.
library;

import 'autostart_stub.dart' if (dart.library.io) 'autostart_io.dart' as host;

/// The argument a login launch passes, so the app can start in the tray
/// instead of in front of whatever the user opened first.
const autostartArgument = '--autostart';

abstract class Autostart {
  /// Whether this computer will start the app at the next sign-in.
  Future<bool> isEnabled();

  /// Registers or removes the login launch.
  Future<void> setEnabled(bool on);
}

/// This host's login launch, or null where there is none (web, phones, or a
/// desktop that cannot offer it).
Future<Autostart?> hostAutostart() => host.hostAutostart();
