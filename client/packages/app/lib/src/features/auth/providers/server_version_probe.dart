// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one `/version` read behind the client floor and the identity recheck.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/providers.dart';
import '../../../providers/sync_controller.dart';

/// What the server says about itself, read again each time the sync reaches live.
///
/// Only that edge re-asks: a reconnect is when a redeployed server can first be
/// seen, while connecting and offline flips during an outage would just repeat
/// a failing request. Null when the read failed, because both readers fail open.
final serverVersionProbeProvider = FutureProvider<api.Version?>((ref) async {
  ref.listen(syncControllerProvider, (previous, next) {
    if (next == SyncStatus.live && previous != SyncStatus.live) {
      ref.invalidateSelf();
    }
  });
  try {
    return await ref.watch(apiProvider).version();
  } catch (error, stack) {
    api.reportFailure(api.LogTag.auth, 'read the server version', error, stack);
    return null;
  }
});
