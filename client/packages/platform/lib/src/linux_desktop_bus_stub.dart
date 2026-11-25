// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The web stand-in for `linux_desktop_bus_io.dart`: a browser has no session bus.
library;

/// Always false: a browser has no session bus.
bool linuxSessionBusEnabled = false;

/// Shows an unread count on the launcher entry; a no-op here.
class LinuxLauncherCount {
  LinuxLauncherCount({Future<void> Function(int count)? emit});

  Future<void> set(int count) async {}
}

/// The activation token a notification server hands over with a click; none here.
class LinuxActivationToken {
  LinuxActivationToken({Stream<String>? tokens, DateTime Function()? clock});

  void listen() {}

  String? take() => null;
}
