// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reaction toggles sent one at a time per message and emoji, so the server
/// sees them in tap order and ends on the last one.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One emoji on one message.
typedef ReactionKey = ({String messageId, String emoji});

/// The toggles still out: present while one is in flight, holding the newest
/// state tapped meanwhile, which goes out once the first answer is in.
final reactionTogglesInFlightProvider = Provider<Map<ReactionKey, bool?>>(
  (ref) => <ReactionKey, bool?>{},
);

/// Sends [want] for [key], or leaves it queued behind the toggle in flight.
///
/// [held] is what the server held before this tap, and [send] answers whether
/// the server took a state. Returns what the server holds once the queue has
/// drained, or null when this tap only queued behind another.
Future<bool?> sendReactionInOrder(
  Map<ReactionKey, bool?> inFlight,
  ReactionKey key, {
  required bool want,
  required bool held,
  required Future<bool> Function(bool active) send,
}) async {
  if (inFlight.containsKey(key)) {
    inFlight[key] = want;
    return null;
  }
  var serverHolds = held;
  bool? next = want;
  try {
    while (next != null) {
      inFlight[key] = null;
      if (next != serverHolds && await send(next)) serverHolds = next;
      next = inFlight[key];
    }
  } finally {
    inFlight.remove(key);
  }
  return serverHolds;
}
