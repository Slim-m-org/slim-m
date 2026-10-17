// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The three rules that decide what goes *between* two messages: whether the
/// second continues the first, whether the "new messages" divider lands on
/// it, and whether a new day starts there.
///
/// Split out of message_transcript.dart to stay under this repo's line
/// budget. These three came out together because they are the only pure
/// functions in that file - each takes a message and its predecessor and
/// answers one question, with no widget, state or context involved - which is
/// also why they are the part worth testing directly.
library;

import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

/// A continuation of the same author's previous message inside the density's
/// grouping window drops its avatar and header. A webhook posting under a
/// different username starts a new group so its label shows.
bool isGrouped(
  Message message,
  Message? previous, {
  String? webhookUsername,
  String? previousWebhookUsername,
}) =>
    previous != null &&
    previous.authorId == message.authorId &&
    webhookUsername?.trim() == previousWebhookUsername?.trim() &&
    (message.createdAt - previous.createdAt).abs() <
        AppDensity.normal.groupWindow.inMilliseconds;

/// True for the first message past the read marker, so the "New" divider
/// lands exactly once, directly above it.
/// True when this message is the first unread one, so the "new messages"
/// divider lands exactly once.
///
/// A message [selfId] wrote is never unread to them, however far the read
/// marker is behind. Without that, sending a message flashed the divider
/// above it for the instant between the optimistic insert and the read
/// marker catching up - the message was, briefly and literally, newer than
/// the last thing this account had read.
///
/// The comparison is guarded on [selfId] being non-null rather than written
/// as `authorId != selfId`: an anonymised author is also null, and the plain
/// form silently treats a deleted account's message as this account's own.
bool startsUnread(
  Message message,
  Message? previous,
  int lastReadSeq,
  String? selfId,
) =>
    !(selfId != null && message.authorId == selfId) &&
    message.seq > lastReadSeq &&
    (previous == null || previous.seq <= lastReadSeq);

/// True when this message falls on a different calendar day than the one above
/// it, so a day divider lands exactly once at each day boundary. The oldest
/// loaded message ([previous] null) also counts, anchoring the top of the
/// transcript with the day it began - but only once [historyKnown] confirms
/// this channel's initial catch-up has actually run at least once.
///
/// Without that gate, an optimistic send made before catch-up completes is
/// briefly the sole loaded row purely because nothing else has landed yet,
/// not because it is really first: catch-up then lands with an earlier
/// same-day message, and the divider that had anchored the sent message
/// flashes onto it and is removed (docs/BACKLOG.md, "sending a message
/// flashes a day divider"). This can happen whether or not the sent message
/// itself is still pending: the send's own round trip is often faster than
/// the (multi-request) catch-up it happens to race.
bool isNewDay(
  Message message,
  Message? previous, {
  required bool historyKnown,
}) {
  if (previous == null) return historyKnown;
  final a = DateTime.fromMillisecondsSinceEpoch(previous.createdAt);
  final b = DateTime.fromMillisecondsSinceEpoch(message.createdAt);
  return a.year != b.year || a.month != b.month || a.day != b.day;
}
