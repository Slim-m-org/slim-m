// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Waiting for the splash to be mapped before the handoff touches the window.
library;

import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException;

import 'close_behavior.dart' show DesktopPlatform, currentDesktopPlatform;
import 'package:slimm_api/api.dart' show AppLog, LogTag;

/// Named to match `linux_window_mapped_channel.cc`, the only handler.
const _channelName = 'top.npcserver.slimm/linux_window_mapped';

/// Longer than the shell's setup timeout: a loaded host can take seconds to
/// paint a first frame, and giving up early is what lets the splash be skipped.
const _timeout = Duration(seconds: 15);
const _poll = Duration(milliseconds: 50);

/// How long the splash has been mapped, or null before it is. Only the Linux
/// runner can tell; elsewhere, or with no handler, it is taken as long mapped.
Future<Duration?> queryNativeWindowMapped() async {
  if (currentDesktopPlatform() != DesktopPlatform.linux) return _longMapped;
  try {
    final ms = await const MethodChannel(
      _channelName,
    ).invokeMethod<int>('isMapped');
    return ms == null || ms < 0 ? null : Duration(milliseconds: ms);
  } on MissingPluginException catch (error, stack) {
    AppLog.swallowed(
      LogTag.platform,
      'Could not ask the system whether the splash window is on screen',
      error,
      stack,
    );
    return _longMapped;
  }
}

const _longMapped = Duration(days: 1);

/// A handoff that hides and resizes a window the window manager has not
/// mapped yet makes X create it at the real size, so the splash is never
/// seen. Bootstrap can beat the first frame on a loaded host, hence this
/// wait. Once mapped, whatever is left of [floor] is measured from the map,
/// not from bootstrap, so a late splash still gets its full dwell. Bounded
/// and swallowed: a window that never maps must not strand the app.
Future<void> awaitSplashMapped({
  Duration floor = Duration.zero,
  Future<Duration?> Function() probe = queryNativeWindowMapped,
}) async {
  final deadline = DateTime.now().add(_timeout);
  try {
    Duration? onScreen;
    while ((onScreen = await probe()) == null) {
      if (DateTime.now().isAfter(deadline)) {
        AppLog.warning(
          LogTag.platform,
          'The splash window was not on screen before the main window opened',
        );
        return;
      }
      await Future<void>.delayed(_poll);
    }
    final remaining = floor - onScreen!;
    if (remaining > Duration.zero) await Future<void>.delayed(remaining);
  } catch (error, stack) {
    AppLog.warning(
      LogTag.platform,
      'Could not confirm the splash window is on screen',
      error: error,
      stack: stack,
    );
  }
}
