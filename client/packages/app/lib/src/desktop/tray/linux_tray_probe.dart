// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Linux-only runtime check for whether a tray host is actually present
/// on the session bus right now - `org.kde.StatusNotifierWatcher`'s own
/// `IsStatusNotifierHostRegistered` property, read through a small
/// hand-written GDBus channel (`linux/runner/linux_tray_probe_channel.cc`)
/// rather than a general-purpose Dart D-Bus package for one boolean.
///
/// KDE implements the watcher natively; GNOME Shell dropped legacy tray
/// icons and needs the third-party AppIndicator extension, so this is the
/// difference between a close that reaches a tray icon and one that would
/// hide the window with nothing to bring it back - see decision 0012.
library;

import 'package:flutter/services.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

const _channelName = 'top.npcserver.slimm/linux_tray_probe';

abstract interface class LinuxTrayProbe {
  /// Whether a StatusNotifierItem host is registered on the session bus
  /// right now. Absent, false, and an error all read as false: a stale
  /// "yes" would leave the window reachable by nothing at all, the one
  /// failure mode this probe exists to prevent.
  Future<bool> isHostRegistered();
}

class MethodChannelLinuxTrayProbe implements LinuxTrayProbe {
  const MethodChannelLinuxTrayProbe({
    MethodChannel channel = const MethodChannel(_channelName),
  }) : _channel = channel;

  final MethodChannel _channel;

  @override
  Future<bool> isHostRegistered() async {
    try {
      final result = await _channel.invokeMethod<bool>('isHostRegistered');
      return result ?? false;
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.platform,
        'is host registered failed, ignored',
        error,
        stack,
      );
      return false;
    }
  }
}
