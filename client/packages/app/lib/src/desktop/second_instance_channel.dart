// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The native runners' notice that a second launch was turned away.
library;

import 'dart:async';

import 'package:flutter/services.dart' show MethodCall, MethodChannel;

/// Receives the runners' `focus` call: the Linux GtkApplication re-entering
/// `activate`, or the Windows runner's named mutex. The Windows runner also
/// sends `link` with the `slimm://` link a later launch was opened with.
class SecondInstanceChannel {
  /// Named to match the senders, `linux_second_instance_channel.cc` and
  /// the Windows runner's `single_instance.cpp`.
  static const _name = 'top.npcserver.slimm/second_instance';

  final _launches = StreamController<void>.broadcast();

  /// Fires each time another launch hands over to this running instance.
  Stream<void> get launches => _launches.stream;

  final _links = StreamController<Uri>.broadcast();

  /// The links later launches handed over, for the deep-link listener.
  Stream<Uri> get links => _links.stream;

  /// Listens for `focus`, running [bringForward] after announcing it, and
  /// for `link`, which only passes the link on: the runner follows it with
  /// its own `focus`.
  ///
  /// Best-effort: the process-level dedup this exists for already happened
  /// natively, in `my_application.cc`'s own early return, before this ran.
  void register(Future<void> Function() bringForward) {
    const MethodChannel(_name).setMethodCallHandler((MethodCall call) async {
      switch (call.method) {
        case 'link':
          final uri = Uri.tryParse('${call.arguments ?? ''}');
          if (uri != null && uri.scheme == 'slimm') _links.add(uri);
        case 'focus':
          _launches.add(null);
          await bringForward();
      }
    });
  }
}
