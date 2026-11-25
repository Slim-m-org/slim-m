// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Declining a ring from the system's own surface, such as Android's notification.
library;

import 'package:slimm_api/api.dart' as api;

import 'dm_call_ring_state.dart';

/// Declines the ring a system decline of [callId] means; [held] is the one the controller has.
Future<void> declineFromSystem(
  String callId, {
  required IncomingDmCallRing? held,
  required api.SlimmApi client,
  required bool Function() isMounted,
  required Future<void> Function(IncomingDmCallRing) decline,
}) async {
  final candidates = held != null ? [held] : await outstandingRings(client);
  if (!isMounted()) return;
  final target = ringToDecline(callId, candidates);
  if (target != null) await decline(target);
}

/// The ring a system decline of [callId] means, among [candidates]: the one with that ring id,
/// else the only one waiting, else none.
IncomingDmCallRing? ringToDecline(
  String callId,
  List<IncomingDmCallRing> candidates,
) {
  for (final ring in candidates) {
    if (ring.ringId == callId) return ring;
  }
  return candidates.length == 1 ? candidates.first : null;
}

/// The server's outstanding rings as the controller holds them; a failed lookup is none.
Future<List<IncomingDmCallRing>> outstandingRings(api.SlimmApi client) async {
  try {
    final rings = await client.listIncomingDmCallRings();
    return [
      for (final ring in rings)
        IncomingDmCallRing(
          channelId: ring.channelId,
          ringId: ring.ringId,
          callerId: ring.callerId,
        ),
    ];
  } on Exception catch (error, stack) {
    api.reportFailure(
      api.LogTag.voice,
      'look up the call that was declined',
      error,
      stack,
    );
    return const [];
  }
}
