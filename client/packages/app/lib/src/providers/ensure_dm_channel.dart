// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show SlimmApiDms;

import 'dms.dart';
import 'providers.dart';

/// Puts the DM [channelId] into the local store if it is not there yet.
///
/// A DM another account just opened reaches this client only on its next
/// channel refresh, and a route to a channel the store lacks reads as "not
/// found or no access". Best-effort: a failure leaves the store as it was.
Future<void> ensureDmChannelLoaded(Ref ref, String channelId) async {
  try {
    final store = await ref.read(storeProvider.future);
    final known = await store.allChannels();
    if (known.any((c) => c.id == channelId)) return;
    final client = ref.read(apiProvider);
    final selfId = client.session.tokens?.userId;
    final dms = await client.listDirectMessages();
    final match = dms.where((d) => d.channelId == channelId);
    if (match.isEmpty) return;
    await store.upsertChannels([channelFromDm(match.first, selfId: selfId)]);
  } on Object {
    // A failed store or fetch must not block the call; the next refresh still heals it.
  }
}
