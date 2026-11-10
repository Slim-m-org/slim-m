// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where shares come from: Android's share sheet, through
/// `ShareIntakeChannel.kt`, and nowhere on the other platforms.
///
/// The native side copies each shared `content://` file into the app cache
/// before answering, because the grant behind the URI ends with the intent.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;
import 'package:slimm_platform/platform.dart' show isAndroidHost;

import 'incoming_share.dart';

abstract interface class ShareSource {
  /// A share arrived while the app was already running; [take] fetches it.
  Stream<void> get arrivals;

  /// The share waiting, once; null when there is none. A cold start finds the
  /// launching share here, so this is called once at startup too.
  Future<IncomingShare?> take();
}

class ChannelShareSource implements ShareSource {
  ChannelShareSource() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'arrived') _arrivals.add(null);
    });
  }

  static const _channel = MethodChannel('top.npcserver.slimm/share_intake');
  final _arrivals = StreamController<void>.broadcast();

  @override
  Stream<void> get arrivals => _arrivals.stream;

  @override
  Future<IncomingShare?> take() async {
    try {
      return IncomingShare.fromWire(
        await _channel.invokeMethod<Object>('take'),
      );
    } on PlatformException catch (error, stack) {
      AppLog.warning(
        LogTag.platform,
        'Could not read the shared items',
        error: error,
        stack: stack,
      );
      return null;
    }
  }
}

class NoShareSource implements ShareSource {
  const NoShareSource();

  @override
  Stream<void> get arrivals => const Stream.empty();

  @override
  Future<IncomingShare?> take() async => null;
}

/// Overridden in tests; the real source exists on Android only.
final shareSourceProvider = Provider<ShareSource>(
  (ref) => isAndroidHost ? ChannelShareSource() : const NoShareSource(),
);
