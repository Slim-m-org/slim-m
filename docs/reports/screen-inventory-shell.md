# Screen inventory: home shell, channel rail, conversation pane, threads, member pane

Part of [screen-inventory.md](screen-inventory.md).
"Surfaces harness" = `client/packages/app/test/ui_snapshot_test.dart`. "Overlay harness" = `client/packages/app/test/snapshots/ui_overlay_snapshot_test.dart`.

A cross-cutting caveat worth reading before the list: the surfaces harness's `_NoopSyncController` never advances past `SyncStatus.offline`, and its fake HTTP client answers every unmatched GET with an empty JSON array.
That means the rail's connection dot, day dividers (gated on `initialSyncCompleteProvider`), and the "still catching up" / "genuinely empty" transcript states are **structurally unreachable** in the current harness, not merely unexercised by an oversight.
It also means whichever of "there is more history above" vs. the channel start header actually renders for `c-general` depends on how `ChannelHistory.atStart` resolves during the two settle-pumps — plausible either way from reading the code, not confirmed by running it.

## Channel rail

- **rail-expanded-docked** — the rail beside the conversation at medium/expanded width. Coverage: covered, every `channel`/`voice`/`thread` viewport at or above `desktop-narrow`.
- **rail-collapsed-icon-strip** — rail unmounted, bare `AppIcons.sidebar` glyph shown instead. Reach: click the divider/glyph, flips `channelRailVisibleProvider` (resets on relaunch). Coverage: none.
- **rail-divider-hover-tint** — accent-tinted `VerticalDivider` on pointer hover, desktop only. Coverage: none (no hover simulation in the harness).
- **rail-search-trigger-with-hint** vs **rail-search-trigger-touch** — the `Ctrl+K` keycap hint shows only on pointer platforms, hidden under `AppTouchTargets`. Coverage: incidentally covered by phone-vs-desktop viewports, though the palette it opens is not (see overlays doc).
- **rail-loading** — bare spinner while the local store resolves. Coverage: none (transient).
- **rail-store-error** — "Could not load channels." Reach: drift database failed to open. Coverage: none.
- **rail-reorder-error-banner** — inline `AppErrorState` above the list when a drag-reorder PATCH fails. Coverage: none.
- **rail-reorder-drag-in-progress** — mid-drag visual state of `ReorderableChannelRows`. Coverage: none.
- **rail-dm-section-empty** — "Start one from the member list." Coverage: this is what the harness actually renders (no `dm`-kind channel is seeded).
- **rail-dm-section-populated** — `DmRow` list, unread/selected variants. Coverage: none.
- **rail-personal-space-never-opened**, **-opened**, **-opening**, **-hidden**, **-open-failed** — the self-DM row's five states. Only "never opened" is what the fixture actually shows; the other four need a real self-DM or a forced failure. Coverage: none of the other four.
- **rail-channel-category-sections** — categorised + implicit uncategorised "Channels" header. Coverage: covered.
- **rail-text-channel-row** / **rail-voice-channel-row** — distinct icon and roster treatment. Coverage: both covered (`c-general`, `c-main`).
- **rail-channel-row-unread-badge** — unread badge on `AppListRow`. Coverage: uncertain whether the fixture's cursor/lastReadSeq values produce a positive delta; not confirmed either way by reading alone.
- **rail-manage-channel-kebab-visible** vs **-hidden** — gated on `canManageChannels`. Coverage: only the visible case (fixture user holds every permission bit); the ordinary-member hidden case is not covered.
- **rail-header-connection-dot** — three shapes for live/connecting/offline. Coverage: only the offline shape is reachable in the harness, since `_NoopSyncController` never leaves it; the "connected" and "connecting" dot shapes have no route to a screenshot today.
- **rail-footer-idle** (not in a call) vs **rail-footer-in-call-elsewhere** (`AnimatedSize` growing to show `RailCallSummary`) — the latter needs a connected call on a channel other than the one on screen. Coverage: not covered; `voice-in-call`'s own route is the call channel itself, so "elsewhere" never triggers.
- **rail-footer-mic-deafen-disabled** (no call) vs **-enabled** (in a call) — both covered.
- **compact-drawer-rail** — same rail inside `Scaffold.drawer`, edge-swipe reachable only at compact width with a channel selected. Coverage: present in the tree, never opened by either harness.
- **compact-app-bar-suppressed** — the compact app bar and drawer are both omitted while canvas or a DM call is open. Coverage: covered by the `canvas`/`canvas-voice` surfaces at the compact bracket.
- **compact-member-pane-end-drawer** — member pane as an end-drawer at compact width, withheld for a DM. Coverage: present, never opened.
- **compact-voice-strip-indicator** — bottom-pinned call strip shown at compact width when connected to a different channel than the one on screen. Coverage: none. See the voice doc for the strip itself.
- **rail-command-palette-open** — see the overlays doc; opened from the search trigger or `Ctrl+K`.

## No channel selected

- **no-channel-selected-wide** — `NoChannelSelected`, "Pick a channel to start reading," beside the docked rail. Reach: `/channels` at medium/expanded width. **Coverage: none — this route is not in the surfaces harness's `_surfaces` map at all**, despite being the default landing state after a fresh sign-in.
- **no-channel-selected-compact** — same widget, single-pane, rail reachable only via drawer. Coverage: none.
- **no-channel-selected-oversized-id** — a channel id over 128 characters silently redirects to this same screen rather than attempting `ConversationPane`. Reach: a corrupted deep link or stale bookmark. Coverage: none.

## Text channel

- **text-normal-wide** / **text-normal-compact** — full `ChannelHeader` vs `CompactChannelAppBar`, messages loaded, composer live. Coverage: both covered (`channel` surface).
- **text-search-open** — `ChannelSearchBar`/`ChannelSearchResults`, itself four sub-states (results, loading, failed, forbidden-403). Coverage: none; search is never toggled by the harness.
- **text-still-catching-up** — empty transcript + `SyncStatus.connecting`, "Catching up on messages..." Coverage: none, structurally unreachable in the current harness (status never leaves offline).
- **text-offline-empty** — empty transcript + `SyncStatus.offline`, "Offline. Messages will appear once reconnected." Coverage: none (fixture channel always has seeded messages).
- **text-genuinely-empty** — empty transcript + `SyncStatus.live`, "No messages yet." Coverage: none, structurally unreachable today (status never reaches live).
- **history-top-more** — "There is more history above," idle. Plausible but unconfirmed as what actually renders for `c-general` — see the caveat above.
- **history-top-loading** — spinner, "Loading earlier messages..." Reach: an in-flight `loadOlder()` triggered automatically on layout. Coverage: uncertain whether it resolves inside the harness's settle window; not confirmed either way.
- **history-top-failed** — `AppErrorState`, "Could not load earlier messages," retry. Coverage: none (fixture never fails a fetch).
- **channel-start-header** — "Welcome to #name" plus real topic, or a generic start-of-channel line with no topic. Reach: `history.atStart == true`. Plausible alternate to `history-top-more` above for the same fixture; which one actually renders was not confirmed by static reading.
- **day-divider-present** — Reach: `initialSyncCompleteProvider` true. Coverage: none, structurally unreachable in the harness.
- **grouped-consecutive-rows** — same-author adjacent messages drop the repeated avatar/header. Coverage: none — the fixture's three `c-general` messages alternate author, so grouping never demonstrates.
- **unread-divider-new** — one-shot "New" divider above the first unread message. Coverage: uncertain whether the fixture's seed data produces it.
- **reactions-rendered** — real counts, filled vs outline "reacted" chip. Coverage: covered (`m-2` carries two reaction summaries).
- **reactions-hover-quick-react** — floating hover cluster, pointer-only. Coverage: none.
- **reply-banner-active** — `ReplyBanner` above the composer while replying. Coverage: none.
- **inline-edit-active** — a row swapped for `MessageEditField`. Coverage: none.
- **failed-send-row** — pending message with retry/discard. Coverage: none.
- **jump-highlight-flash** — highlight after a search/reply-quote jump. Coverage: none.
- **pinned-indicator-on-row** — does not exist as a state; there is no inline "pinned" badge on a transcript row (pin state only shows via the header pin pill and the separate pinned-messages sheet). Noted so nobody goes looking for it.
- **context-menu-own-message**, **-others-plain-member**, **-others-manage-messages-holder** — item sets differ by authorship and `MANAGE_MESSAGES`. Coverage: none (interaction-only, not opened by either harness).
- **thread-reply-summary-absent** (null), **-present** (real count > 0), **-zero-real** (opened, empty thread, distinct from no-thread-at-all), **-inert-text** (rendered non-tappable when `canOpenThread` is false). Coverage: none — the harness's messages carry no thread fields at all, so only the absent state ever renders.

## Voice channel (join preview only; see the voice doc for the connected states)

- **voice-join-preview** — covered by the `voice` surface, but per that file's own comment it only ever reaches the join-preview family, never a connected call.

## DM channel

- **dm-normal-transcript** — member pane withheld, header member toggle skipped. Coverage: none — no `dm`-kind channel is seeded anywhere in the surfaces harness.
- **dm-blocked-transcript** — see the moderation doc (`dm-blocked-by-me`).
- **dm-call-pane** — see the voice doc.
- **dm-personal-space-conversation** — the self-DM's own transcript (notes-to-self). Coverage: none.

## Thread (`/thread/:channelId`)

- **thread-opened-normally** — minimal `AppBar` ("Thread," back button, its own scoped search — no pin pill, no canvas button, no rail/member toggles) wrapping `ChannelScreen(isThread: true)`. Coverage: covered (`thread` surface, `/thread/c-thread`).
- **thread-opened-by-deep-link** — the historically buggy "e2e was red for a day" case. Structurally closed now (`ThreadScreen` sets `isThread: true` unconditionally), so visually identical to the normal case; the harness's pre-seeded row doesn't specifically exercise the "row absent" path either way.
- **thread-search-open** — the thread's own scoped search bar. Coverage: none.
- **thread-genuinely-empty** — `ChannelStartHeader(isThread: true)`, "Replies to the original message appear here." Coverage: none (`c-thread` has two seeded messages).

## Member pane

- **member-pane-loading** — spinner, count null. Coverage: likely resolves before any settled frame; effectively uncaptured either way.
- **member-pane-error-retry** — "Could not load members." + Retry, any non-403 failure. Coverage: none.
- **member-pane-error-forbidden** — same text, no Retry, on a 403. Coverage: none.
- **member-pane-loaded-grouped** — Online/Offline groups, role badge, status dots. Coverage: covered structurally, but the "Online" group is plausibly always empty in the harness since presence resolves through a fetch the fake API answers generically — worth capturing the real grouped-with-online state deliberately rather than trusting this counts as proof of it.
- **member-pane-self-row** — no DM-open affordance on your own row. Coverage: covered.
- **member-pane-hidden-below-medium-width** — pane absent below the member-pane width floor. Coverage: covered (`expanded-999`/`expanded-1000` pair).
- **member-pane-withheld-for-dm** — suppressed for a DM regardless of toggle state. Coverage: none (no DM channel seeded).
- **member-pane-compact-drawer** — same pane as an end-drawer. Coverage: none, never opened.
- **member-row-profile-popover** — see the overlays and moderation docs.
