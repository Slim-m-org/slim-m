// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether this Android device is a Firebase Test Lab device.
///
/// Google's automated runs (the Play pre-launch report) execute on those
/// devices, and Test Lab sets the `firebase.test.lab` system setting there.
/// Every other host answers false without asking.
library;

import 'package:flutter/services.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

import 'host_platform.dart';

const _channelName = 'top.npcserver.slimm/test_lab';

class TestLabChannel {
  TestLabChannel({MethodChannel? channel, bool? isAndroid})
      : _channel = channel ?? const MethodChannel(_channelName),
        _isAndroid = isAndroid ?? isAndroidHost;

  final MethodChannel _channel;
  final bool _isAndroid;

  /// False off Android and whenever the native side cannot answer.
  Future<bool> isTestLabDevice() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('isTestLab') ?? false;
    } on PlatformException catch (error, stack) {
      AppLog.swallowed(
          LogTag.platform, 'Could not read the test lab flag', error, stack);
    } on MissingPluginException catch (error, stack) {
      AppLog.swallowed(
          LogTag.platform, 'Could not read the test lab flag', error, stack);
    }
    return false;
  }
}
