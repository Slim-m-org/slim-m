// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one `/version` read behind the client floor and the identity recheck.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/providers.dart';
import '../../../providers/sync_controller.dart';
import 'server_identity_proof.dart';

/// One read of `/version`: [answered] is false only when nothing came back,
/// so a reply that is not a slim-m `/version` can be told apart from an outage.
typedef VersionRead = ({api.Version? version, bool answered});

/// How long to wait before asking again after an answer that was not a slim-m
/// `/version`, as a proxy gives while the server behind it restarts.
final versionRetryDelaysProvider = Provider<List<Duration>>(
  (ref) => const [Duration(seconds: 2), Duration(seconds: 5)],
);

/// What the server says about itself, read again each time the sync reaches live.
///
/// Only that edge re-asks: a reconnect is when a redeployed server can first be
/// seen, while connecting and offline flips during an outage would just repeat
/// a failing request. The identity recheck may also ask for a fresh read when
/// a plain-http connection drops.
final serverVersionReadProvider = FutureProvider<VersionRead>((ref) async {
  ref.listen(syncControllerProvider, (previous, next) {
    if (next == SyncStatus.live && previous != SyncStatus.live) {
      ref.invalidateSelf();
    }
  });
  final client = ref.watch(apiProvider);
  final delays = ref.watch(versionRetryDelaysProvider);
  for (var attempt = 0; ; attempt++) {
    try {
      return (version: await client.version(), answered: true);
    } catch (error, stack) {
      api.reportFailure(
        api.LogTag.auth,
        'read the server version',
        error,
        stack,
      );
      if (!serverAnswered(error)) return (version: null, answered: false);
      if (attempt >= delays.length) return (version: null, answered: true);
      await Future<void>.delayed(delays[attempt]);
    }
  }
});

/// The version alone, null when the read failed, because the floor fails open.
final serverVersionProbeProvider = FutureProvider<api.Version?>(
  (ref) async => (await ref.watch(serverVersionReadProvider.future)).version,
);
