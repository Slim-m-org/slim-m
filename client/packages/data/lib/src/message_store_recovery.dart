// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'message_store.dart';

/// What a send interrupted by the process ending is told it was.
///
/// Named rather than inlined so a test can assert the row it finds carries
/// this exact reason and not some other failure that happened to be pending.
const String interruptedSendReason =
    'The app closed before this finished sending.';

/// Marks every send still `pending` as failed, and says how many.
///
/// A send writes its row `pending: true`, then either lands and is replaced by
/// the server's copy, or catches an `ApiException` and is marked failed. If the
/// process ends between those - a crash, a force-quit, the OS reclaiming a
/// backgrounded app - neither branch ever runs and the row stays pending for
/// good.
///
/// Nothing rescues it. `failedMessages`, which the reconnect retry reads,
/// selects `failed`; the row's own Retry button is offered for `failed`. So the
/// message sits reading as sending forever, is never retried, and cannot be
/// retried by hand - the one state in the send lifecycle with no way out.
///
/// Turning it into a failure gives it both back, and replaying is safe rather
/// than merely convenient: `retryMessage` resends under the original id and the
/// server's send route is idempotent by (channel, author, id), so a send that
/// did reach the server before the process died lands on the same row instead
/// of posting twice.
///
/// **Only ever called as the store is opened**, before the run that opens it
/// can issue a send of its own. A row found then belongs to a process that no
/// longer exists; the same sweep run mid-session could catch a live request.
/// A top-level function taking the store, the shape `message_store_batch`
/// already uses, rather than a method on [MessageStore]: that class sits three
/// lines under its file's ceiling, and this has exactly one caller.
Future<int> failInterruptedSends(MessageStore store) =>
    (store.db.update(store.db.messages)
          ..where((m) => m.pending.equalsExp(const Constant(true))))
        .write(
      const MessagesCompanion(
        pending: Value(false),
        failed: Value(true),
        failureReason: Value(interruptedSendReason),
      ),
    );
