// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sign-in from an unfamiliar device that this one is currently warning
/// about, if any.
///
/// Held in memory only: the server sends it once to sockets that are open
/// when it happens, and the devices list is where anyone who missed it can
/// still find the device. `startAccountServices` keeps it alive for the life
/// of the account's container, so an account out of view still holds its alert.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import '../../../providers/live_events.dart';
import '../../../providers/providers.dart' show sessionProvider;

class NewDeviceAlertController extends StateNotifier<NewDeviceSignIn?> {
  NewDeviceAlertController(Stream<ServerEvent> events, Stream<bool> signedIn)
    : super(null) {
    _subscription = events.listen((event) {
      if (event is NewDeviceSignIn) state = event;
    });
    _signedInSubscription = signedIn.listen((isSignedIn) {
      if (!isSignedIn) state = null;
    });
  }

  late final StreamSubscription<ServerEvent> _subscription;
  late final StreamSubscription<bool> _signedInSubscription;

  void dismiss() => state = null;

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    unawaited(_signedInSubscription.cancel());
    super.dispose();
  }
}

/// Cleared on sign-out, so the alert is never shown to the next account on this device.
final newDeviceAlertProvider =
    StateNotifierProvider.autoDispose<
      NewDeviceAlertController,
      NewDeviceSignIn?
    >(
      (ref) => NewDeviceAlertController(
        ref.watch(liveEventsProvider),
        ref.read(sessionProvider).changes.map((tokens) => tokens != null),
      ),
    );
