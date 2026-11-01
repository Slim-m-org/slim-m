// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sign-in from an unfamiliar device that this one is currently warning
/// about, if any.
///
/// Held in memory only: the server sends it once to sockets that are open
/// when it happens, and the devices list is where anyone who missed it can
/// still find the device.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import '../../../providers/live_events.dart';

class NewDeviceAlertController extends StateNotifier<NewDeviceSignIn?> {
  NewDeviceAlertController(Stream<ServerEvent> events) : super(null) {
    _subscription = events.listen((event) {
      if (event is NewDeviceSignIn) state = event;
    });
  }

  late final StreamSubscription<ServerEvent> _subscription;

  void dismiss() => state = null;

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    super.dispose();
  }
}

/// Auto-disposed so a sign-out drops the alert instead of showing it to the
/// next account on this device.
final newDeviceAlertProvider =
    StateNotifierProvider.autoDispose<
      NewDeviceAlertController,
      NewDeviceSignIn?
    >((ref) => NewDeviceAlertController(ref.watch(liveEventsProvider)));
