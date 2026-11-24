// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One native-to-Dart handler per method channel, shared by every listener.
///
/// A [MethodChannel] keeps a single handler, so each account container
/// installing its own would silence all but the last. The hub installs it
/// while anyone listens and removes it once nobody does.
library;

import 'dart:async';

import 'package:flutter/services.dart';

final _hubs = <MethodChannel, MethodChannelHub>{};

class MethodChannelHub {
  MethodChannelHub._(MethodChannel channel) {
    _calls = StreamController<MethodCall>.broadcast(
      sync: true,
      onListen: () => channel.setMethodCallHandler((call) async {
        _calls.add(call);
      }),
      onCancel: () => channel.setMethodCallHandler(null),
    );
  }

  late final StreamController<MethodCall> _calls;

  static MethodChannelHub of(MethodChannel channel) =>
      _hubs.putIfAbsent(channel, () => MethodChannelHub._(channel));

  /// Every call native makes on the channel, to each listener alike.
  Stream<MethodCall> get calls => _calls.stream;
}
