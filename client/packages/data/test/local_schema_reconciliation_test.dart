// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Pins the property that lets reactions, pins and polls skip reconciliation.
///
/// `CLAUDE.md`'s "Reconciling an edit nobody was online for" names an open
/// debt: an offline client never learns about a reaction, a pin or a poll
/// vote it missed. That is correct today only because none of the three is
/// persisted locally - every REST fetch that returns a message (send, list,
/// sync, search) already carries all of them in full, so a fresh render is
/// always a fresh read rather than a stale cache. `MessageExtras`
/// (`packages/app/lib/src/providers/message_extras.dart`) and
/// `PinsController` (`packages/app/lib/src/providers/pins_controller.dart`)
/// both say so in their own doc comments and both hold their state in plain
/// Riverpod memory, never in this database.
///
/// The day one of them gains a drift table, that reasoning stops applying
/// and the debt reopens - with none of `message_ops`' machinery reusable,
/// since a reaction op is per-viewer (never broadcast with reactor ids) and
/// a pin op is not idempotent by message id the way an edit or delete is.
/// This test is the tripwire: it fails the moment a new table appears here,
/// so whoever adds one is pointed at the debt note before shipping a cache
/// nothing keeps in sync.
///
/// `docs/decisions/0009-reactions-pins-polls-reconciliation.md` is the
/// designed answer for that day: none of the three needs `message_ops`'
/// shape, and each has a cheaper reconciliation already precedented
/// elsewhere in this client. Read it before building one from scratch.
///
/// `channel_categories` (docs/decisions/0006-channel-categories.md) is
/// listed here deliberately rather than reopening that debt: it is replaced
/// wholesale on every channel refresh
/// (`MessageStore.replaceCategories`, called from `ChannelRefresher.refresh`),
/// the same shape `channels` itself already has, never reconciled
/// incrementally the way a reaction, pin or poll vote would need to be. A
/// missed live event only means the next full channel refresh - already
/// triggered by any category change - is what catches it up, not a gap
/// nothing revisits.
///
/// `channel_drafts` is listed for a different reason again, and it is the first
/// table here that is not a cache of anything. The server never has an unsent
/// draft, so there is no authoritative copy for a local one to drift from and
/// nothing a reconciliation could reconcile it against - the debt this test
/// guards is about a local copy of server state going stale, which a draft
/// cannot do. What it needs instead is the opposite guarantee: `MessageStore
/// .clear()` deletes it on sign-out, because the words are real and belong to
/// the account that typed them. See `channel_drafts_store_test.dart`.
///
/// `pending_attachments` is local-only in the same way: the ids an unsent
/// message was queued with, which no server copy exists for until the send
/// lands. It ends with the send (swept at open, wiped by `MessageStore.clear()`
/// on sign-out) and is never reconciled. See `pending_attachments_store_test
/// .dart`.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_data/data.dart';

void main() {
  test('the local schema holds only the tables reasoned about above', () async {
    final db = SlimmDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final names = db.allTables.map((t) => t.actualTableName).toSet();
    expect(
      names,
      {
        'channels',
        'messages',
        'channel_categories',
        'channel_drafts',
        'pending_attachments',
      },
      reason: 'a new local table means either something server-owned just '
          'started being cached - read the reconciliation debt in CLAUDE.md '
          'and build reconciliation for it in the same change - or it is '
          'local-only data like channel_drafts, which needs a sign-out wipe '
          'instead. Say which in this file, the way the five above do.',
    );
  });
}
