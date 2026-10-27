// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The native runners' notice that a second launch was turned away.
library;

import 'dart:async';

import 'package:flutter/services.dart' show MethodCall, MethodChannel;

/// Receives the runners' `focus` call: the Linux GtkApplication re-entering
/// `activate`, or the Windows runner's named mutex.
class SecondInstanceChannel {
  /// Named to match the senders, `linux_second_instance_channel.cc` and
  /// the Windows runner's `single_instance.cpp`.
  static const _name = 'top.npcserver.slimm/second_instance';

  final _launches = StreamController<void>.broadcast();

  /// Fires each time another launch hands over to this running instance.
  Stream<void> get launches => _launches.stream;

  /// Listens for `focus` and runs [bringForward] after announcing it.
  ///
  /// Best-effort: the process-level dedup this exists for already happened
  /// natively, in `my_application.cc`'s own early return, before this ran.
  void register(Future<void> Function() bringForward) {
    const MethodChannel(_name).setMethodCallHandler((MethodCall call) async {
      if (call.method != 'focus') return;
      _launches.add(null);
      await bringForward();
    });
  }
}
