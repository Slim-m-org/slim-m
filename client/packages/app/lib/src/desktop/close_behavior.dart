// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What "close" means on each desktop platform, and the one place that
/// decision is made - decision 0012's close-vs-minimise router, kept as a
/// pure function so the rule is provable without a window ever existing.
library;

import 'package:slimm_platform/platform.dart';

/// The three desktop targets; only Linux needs a runtime probe to pick its
/// close rule.
enum DesktopPlatform { linux, macOS, windows }

/// Null off desktop entirely (mobile, web) - callers gate the whole desktop
/// shell on this being non-null before touching any of it.
DesktopPlatform? currentDesktopPlatform() {
  if (isLinuxHost) return DesktopPlatform.linux;
  if (isMacOSHost) return DesktopPlatform.macOS;
  if (isWindowsHost) return DesktopPlatform.windows;
  return null;
}

/// What the close affordance (the X button, and - per the owner's answer -
/// Alt+F4/window-manager-close on Windows and Linux too, since the platform
/// cannot tell the two apart) should do right now.
enum CloseAction {
  /// The window is hidden and reachable only through a tray or Dock icon.
  hideToTray,

  /// The window is iconified but keeps its taskbar/Alt-Tab entry - the
  /// fallback for Linux when no tray host is registered, so closing never
  /// leaves the app reachable by nothing at all.
  minimizeToTaskbar,
}

/// [platform]'s close behaviour. [trayAvailable] only matters on Linux:
/// macOS's Dock and Windows' notification area are both unconditional, so
/// neither platform needs the runtime probe Linux does.
CloseAction resolveCloseAction({
  required DesktopPlatform platform,
  required bool trayAvailable,
}) => switch (platform) {
  DesktopPlatform.macOS => CloseAction.hideToTray,
  DesktopPlatform.windows => CloseAction.hideToTray,
  DesktopPlatform.linux =>
    trayAvailable ? CloseAction.hideToTray : CloseAction.minimizeToTaskbar,
};
