// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Retries every locally failed send once, the moment `SyncController`
/// reconnects. Split out of `sync_controller.dart` to keep that file under
/// its own line budget, the same reason `ChannelRefresher` lives apart from
/// it: this never touches connection state either.
library;

import 'package:slimm_data/data.dart';

import 'message_actions.dart' show retryMessage;
import 'message_search.dart' show ProviderReader;

/// A send that failed only because the connection was down is safe to
/// replay unconditionally: [retryMessage] resends under the message's own
/// original id, and the server's send route is idempotent by (channel,
/// author, id), so a retry can only ever land on the same row, never post
/// twice. One attempt per reconnect, not a loop: a send that fails again (a
/// permission revoked while offline, say) goes back to failed and waits for
/// either a further reconnect or the person to retry it themselves, rather
/// than this hammering the same doomed request. Manual tap-to-retry from a
/// message row's own Retry button calls the identical [retryMessage] and
/// stays the only route for a send that fails again after this.
///
/// [isCurrent] is checked before every retry, the same guard every other
/// checkpoint in `SyncController.start` uses, so a run superseded by a later
/// sign-out or reconnect stops rather than writing into a store a newer run
/// has since moved past.
Future<void> retryFailedSends(
  ProviderReader read,
  MessageStore store, {
  required bool Function() isCurrent,
}) async {
  final failed = await store.failedMessages();
  for (final message in failed) {
    if (!isCurrent()) return;
    await retryMessage(read, message);
  }
}
