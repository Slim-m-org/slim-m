// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Asks Android 12+ for the Bluetooth grant that call audio routing needs.
///
/// Without `BLUETOOTH_CONNECT` the audio switcher cannot list a headset, so a
/// call stays on the earpiece or speaker. A denial is not an error: the call
/// simply keeps the speaker.
library;

import 'package:flutter/services.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

import 'host_platform.dart';

const _channelName = 'top.npcserver.slimm/bluetooth_permission';

/// A no-op wherever nothing answers this channel, so a caller never checks the platform.
class BluetoothPermissionChannel {
  /// [supported] says whether this host has a native handler; only Android does.
  BluetoothPermissionChannel({MethodChannel? channel, bool? supported})
      : _channel = channel ?? const MethodChannel(_channelName),
        _supported = supported ?? isAndroidHost;

  final MethodChannel _channel;
  final bool _supported;

  /// Whether headsets can be routed to: true on a device that needs no grant (API 30 and older) or was given it.
  Future<bool> request() async {
    if (!_supported) return false;
    try {
      return await _channel.invokeMethod<bool>('request') ?? false;
    } catch (error, stack) {
      AppLog.swallowed(LogTag.platform,
          'Could not ask for the Bluetooth permission', error, stack);
      return false;
    }
  }
}
