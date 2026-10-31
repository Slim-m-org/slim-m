// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one retention policy the client's unbounded local caches are meant to
/// share, rather than each growing its own unrelated cap.
///
/// Four caches currently grow without bound for the life of an install:
/// `data/message_store.dart`'s drift rows (no retention at all, only
/// server-signalled deletes or a full sign-out wipe), `message_extras.dart`'s
/// per-message-id map (its own doc comment explains why a naive per-id prune
/// is unsafe: search, pins, the command palette and a paged-in transcript all
/// render extras for messages outside any one channel's visible rows, so
/// there is no correct answer without knowing what is actually reachable),
/// `channel_history.dart`'s live-watched window (grows on every
/// [ChannelHistoryController.loadOlder], feeding an ever-larger `LIMIT` into a
/// drift watch that re-runs on any write to the messages table), and
/// `user_profiles.dart`'s resolved-profile map.
///
/// Profiling on 2026-08-19 measured an installed store at 884 KB - none of
/// this bites yet, so this file exists to make the eventual fix share one
/// rule rather than to solve a live problem today.
///
/// **The reachability rule**: anything reachable from a still-open channel's
/// live window must survive a sweep. A channel's live window is its newest
/// [cappedChannelWindow] rows - the same bound the transcript itself now
/// respects (see `channel_history.dart`). A future sweep of the message store
/// or of [message_extras.dart]'s map must keep every message in that range,
/// for every channel currently open, and may only ever evict older than that.
///
/// **Landed**: the window ceiling itself, in `channel_history.dart` -
/// `loadOlder()` no longer grows a channel's window without bound, which was
/// the one part of the shared policy that was already an active bug (an
/// ever-larger `LIMIT` re-evaluated by drift on every write, not merely a
/// growing cache). Later, the rest of it: `providers/mounted_channels.dart`
/// is the registry of which channel ids are actually open, and
/// `providers/retention_sweep.dart` is the periodic sweep that caps the
/// local store to [channelWindowCeiling] rows per channel
/// (`MessageStore.pruneToRetentionCeiling`) and then answers
/// `message_extras.dart`'s own reachability question off the capped store,
/// rather than inventing a second rule for it.
///
/// **Deferred**: eviction of whole channels that have not been opened
/// recently, which the sweep above does not attempt - it caps every
/// channel's rows to the ceiling uniformly, open or not, rather than
/// dropping a closed channel's history further. Worth revisiting only if a
/// future profile shows the per-channel cap is not enough on its own.
library;

/// How many of a channel's newest messages the transcript will ever hold in
/// one live-watched window.
///
/// Five times the transcript's opening window (200, see
/// `channel_history.dart`) and twenty times the default backwards-page size
/// (50, see `message_page_size.dart`): generous enough that an ordinary
/// scrollback session never notices it, while still finite. Chosen for the
/// query cost this bounds - a drift `watch` re-runs its whole query on any
/// write to the messages table, so the `LIMIT` this feeds is what "any write,
/// anywhere in this channel" ends up costing - not for memory, which
/// profiling shows nowhere close to a concern at this size.
const channelWindowCeiling = 1000;

/// [requestedWindow] is how large a channel's live-watched window would like
/// to grow to; the result is what it may actually use, and therefore the
/// upper edge of what [channelWindowCeiling]'s reachability rule protects.
///
/// Pure and total so a future store or extras sweep can call this directly
/// rather than re-deriving the bound: the newest [cappedChannelWindow] rows of
/// a channel that is currently open are reachable and must survive; anything
/// older than that is fair game.
int cappedChannelWindow(int requestedWindow) =>
    requestedWindow < channelWindowCeiling
    ? requestedWindow
    : channelWindowCeiling;
