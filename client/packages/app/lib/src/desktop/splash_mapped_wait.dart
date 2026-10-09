// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Waiting for the splash to be mapped before the handoff touches the window.
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException;

import 'close_behavior.dart' show DesktopPlatform, currentDesktopPlatform;

/// Named to match `linux_window_mapped_channel.cc`, the only handler.
const _channelName = 'top.npcserver.slimm/linux_window_mapped';

/// Longer than the shell's setup timeout: a loaded host can take seconds to
/// paint a first frame, and giving up early is what lets the splash be skipped.
const _timeout = Duration(seconds: 15);
const _poll = Duration(milliseconds: 50);

/// Test-only seam for the native answer; a test that reaches the handoff must replace it.
Future<bool> Function() debugSplashMappedProbe = queryNativeWindowMapped;

/// Only the Linux runner can tell; elsewhere, or with no handler, the window
/// is taken as mapped.
Future<bool> queryNativeWindowMapped() async {
  if (currentDesktopPlatform() != DesktopPlatform.linux) return true;
  try {
    return await const MethodChannel(
          _channelName,
        ).invokeMethod<bool>('isMapped') ??
        true;
  } on MissingPluginException {
    return true;
  }
}

/// A handoff that hides and resizes a window the window manager has not
/// mapped yet makes X create it at the real size, so the splash is never
/// seen. Bootstrap can beat the first frame on a loaded host, hence this
/// wait. Bounded and swallowed: a window that never maps must not strand the
/// app.
Future<void> awaitSplashMapped() async {
  final deadline = DateTime.now().add(_timeout);
  try {
    while (!await debugSplashMappedProbe()) {
      if (DateTime.now().isAfter(deadline)) {
        debugPrint('desktop: splash was not mapped before the handoff');
        return;
      }
      await Future<void>.delayed(_poll);
    }
  } catch (error) {
    debugPrint('desktop: splash mapped check failed: $error');
  }
}
