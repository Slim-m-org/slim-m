// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Finding which signed-in account holds a ring, for a call CallKit answered.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../accounts/providers/account_host.dart';
import '../../../providers/providers.dart';

typedef RingElsewhere = ({
  AccountRuntime account,
  api.OutstandingDmCallRing ring,
});

/// The first other signed-in account whose server lists a ring still waiting.
Future<RingElsewhere?> findRingOnOtherAccount(
  AccountHost host,
  ProviderContainer self, {
  String? ringId,
}) async {
  for (final other in host.accounts) {
    if (identical(other.container, self) || !other.signedIn) continue;
    try {
      final rings = await other.container
          .read(apiProvider)
          .listIncomingDmCallRings();
      final ring = ringId == null
          ? rings.firstOrNull
          : rings.where((r) => r.ringId == ringId).firstOrNull;
      if (ring != null) return (account: other, ring: ring);
    } on Exception catch (error, stack) {
      api.reportFailure(
        api.LogTag.voice,
        'look up the call that is ringing on another account',
        error,
        stack,
      );
    }
  }
  return null;
}
