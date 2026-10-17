// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether the window can read and set its own screen position.
///
/// Wayland compositors own placement: a client can neither read where its
/// window is nor ask for a spot, so a position saved there is a made-up value.
library;

import 'dart:io';

/// True for a Wayland session, which the GTK runner follows unless `GDK_BACKEND` forces X11.
bool isWaylandSession(Map<String, String> environment) {
  if (environment['GDK_BACKEND']?.split(',').first == 'x11') return false;
  if (environment['XDG_SESSION_TYPE'] == 'wayland') return true;
  return (environment['WAYLAND_DISPLAY'] ?? '').isNotEmpty;
}

/// Linux on Wayland is the one place a position cannot be trusted; Windows, macOS and X11 keep it.
bool windowPositionSupported({
  bool? isLinux,
  Map<String, String>? environment,
}) {
  if (!(isLinux ?? Platform.isLinux)) return true;
  return !isWaylandSession(environment ?? Platform.environment);
}
