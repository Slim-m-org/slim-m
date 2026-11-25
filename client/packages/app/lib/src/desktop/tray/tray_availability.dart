// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether a tray is reachable right now, combining the platform (macOS's
/// Dock and Windows' notification area are both unconditional) with the
/// Linux-only runtime probe, decision 0012's own split.
library;

import '../close_behavior.dart';
import 'linux_tray_probe.dart';

/// [platform] and [probe] captured once; the returned closure re-checks the
/// probe on every call, since [DesktopWindowController.trayAvailable] must
/// query live rather than cache - a tray host can appear or disappear
/// mid-session (an extension toggled, a panel restarted).
Future<bool> Function() trayAvailabilityCheck({
  required DesktopPlatform platform,
  required LinuxTrayProbe probe,
}) => () async {
  if (platform != DesktopPlatform.linux) return true;
  return probe.isHostRegistered();
};

/// Polls [check] every [interval] until it holds or [timeout] passes, and
/// answers the last result; a login launch can start before the tray host.
Future<bool> waitForTray(
  Future<bool> Function() check, {
  required Duration timeout,
  required Duration interval,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await check()) {
    if (!DateTime.now().add(interval).isBefore(deadline)) return false;
    await Future<void>.delayed(interval);
  }
  return true;
}
