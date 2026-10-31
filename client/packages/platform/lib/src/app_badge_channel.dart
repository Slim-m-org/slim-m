// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The app icon badge on iOS.
///
/// The notification service extension sets the badge when a push arrives;
/// this is how the app corrects it when it knows better. Every other
/// platform makes [sync] a no-op, so a caller needs no platform check.
library;

import 'package:flutter/services.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

import 'host_platform.dart';

const _channelName = 'top.npcserver.slimm/app_badge';

class AppBadgeChannel {
  AppBadgeChannel({MethodChannel? channel, bool? isIOS})
      : _channel = channel ?? const MethodChannel(_channelName),
        _isIOS = isIOS ?? isIOSHost;

  final MethodChannel _channel;
  final bool _isIOS;

  /// Shows [count] on the icon and drops delivered notifications of the
  /// channels in [readChannelIds].
  Future<void> sync({
    required int count,
    required Iterable<String> readChannelIds,
  }) async {
    if (!_isIOS) return;
    try {
      await _channel.invokeMethod<void>('sync', {
        'count': count,
        'readChannelIds': readChannelIds.toList(growable: false),
      });
    } on PlatformException catch (error, stack) {
      AppLog.swallowed(
          LogTag.push, 'Could not set the app badge', error, stack);
    } on MissingPluginException catch (error, stack) {
      AppLog.swallowed(
          LogTag.push, 'Could not set the app badge', error, stack);
    }
  }
}
