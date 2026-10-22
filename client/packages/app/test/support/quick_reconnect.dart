// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A real [SyncController] whose reconnect backoff is milliseconds, for tests
/// that drop a socket to see what happens after it comes back.
library;

import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';

class _NoJitter implements Random {
  @override
  int nextInt(int max) => 0;
  @override
  double nextDouble() => 0;
  @override
  bool nextBool() => false;
}

final Override quickReconnect = syncControllerProvider.overrideWith(
  (ref) => SyncController(
    ref,
    random: _NoJitter(),
    backoffStep: const Duration(milliseconds: 20),
  ),
);
