// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether a Wayland compositor has stopped painting the window, which is the
/// only thing a minimise tells the app there. See `docs/window-states.md`.
library;

import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException;

/// Named to match `linux_window_suspended_channel.cc`, the only handler.
const linuxWindowSuspendedChannel = MethodChannel(
  'top.npcserver.slimm/linux_window_suspended',
);

/// Reports every change to [onChanged], starting from what the runner already
/// knows. A runner with no handler never reports, and the window stays visible.
Future<void> watchLinuxWindowSuspended(
  void Function(bool suspended) onChanged,
) async {
  linuxWindowSuspendedChannel.setMethodCallHandler((call) async {
    if (call.method == 'suspendedChanged') onChanged(call.arguments == true);
  });
  try {
    final suspended = await linuxWindowSuspendedChannel.invokeMethod<bool>(
      'isSuspended',
    );
    if (suspended ?? false) onChanged(true);
  } on MissingPluginException {
    return;
  }
}
