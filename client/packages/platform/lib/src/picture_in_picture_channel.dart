// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Android's picture-in-picture window, bridged from `PictureInPictureBridge.kt`.
///
/// Dart only says whether backing out of the app should float the video
/// ([setEligible]); the activity does the entering, because the platform ties
/// it to the user-leave-hint. [modeChanges] reports the window being entered or
/// left. Android only: elsewhere nothing is sent and the stream stays empty, so
/// a caller needs no platform check of its own.
library;

import 'dart:async';

import 'package:flutter/services.dart';

import 'host_platform.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

const _channelName = 'top.npcserver.slimm/picture_in_picture';

class PictureInPictureChannel {
  PictureInPictureChannel({MethodChannel? channel, bool? isAndroid})
      : _channel = channel ?? const MethodChannel(_channelName),
        _isAndroid = isAndroid ?? isAndroidHost {
    if (_isAndroid) _channel.setMethodCallHandler(_onCall);
  }

  final MethodChannel _channel;
  final bool _isAndroid;
  final _modes = StreamController<bool>.broadcast();

  /// True on entering the floating window, false on leaving it.
  Stream<bool> get modeChanges => _modes.stream;

  Future<void> _onCall(MethodCall call) async {
    if (call.method != 'modeChanged') return;
    final inPictureInPicture = call.arguments;
    if (inPictureInPicture is bool) _modes.add(inPictureInPicture);
  }

  /// Best-effort: a device without the feature answers nothing, and that must
  /// not fail a call that is otherwise fine.
  Future<void> setEligible(bool eligible) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<void>('setEligible', eligible);
    } on PlatformException catch (error, stack) {
      AppLog.swallowed(LogTag.platform,
          'Could not update picture-in-picture availability', error, stack);
      return;
    } on MissingPluginException catch (error, stack) {
      AppLog.swallowed(LogTag.platform,
          'Could not update picture-in-picture availability', error, stack);
      return;
    }
  }

  Future<void> dispose() => _modes.close();
}
