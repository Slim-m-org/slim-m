# Backlog

Status: accepted into backlog, ~~not yet scheduled~~ - several have shipped since; see the note below the table.
Date: 2026-07-23.
Source: the segment gap analysis in [design/feature-exploration.md](design/feature-exploration.md), approved by the owner.

These are agreed features and constraints beyond the v1 core.
None are scheduled yet.
The "Target phase" column is a tentative attachment point; the concrete phase numbers are reconciled into [ROADMAP.md](ROADMAP.md) after the architecture re-plan lands.
Nothing here overrides the founding principles: lightweight and cheap to self-host, one deployment is one community, performance first, and maintainability over feature accumulation.

## Accepted features

Each item is a real backlog entry with the segments that asked for it and a rough size.

| Feature | Segments | Size | Target phase (tentative) |
|---|---|---|---|
| Client-side voice controls: per-user volume mixer, voice-activity sensitivity, desktop push-to-talk | Gamers | M | Voice and screen share |
| Screen-share audio capture plus a quality and frame-rate toggle (desktop-first) | Gamers | M | Voice and screen share |
| Low-bandwidth and data-saver mode (audio-only calls, suppressed image auto-load) | Accessibility, gamers | M | Voice and screen share, client |
| Message editing with edit history | Teams | S | Client shell and text messaging |
| Pinned messages plus personal saved items | Teams, community | S | Client shell and text messaging |
| In-chat polls (native poll message type) | Community | S | Client shell and text messaging |
| Rich markdown and code blocks with a lean syntax highlighter | Teams | M | Client shell and text messaging |
| Advanced search operators (from:, in:, has:, before:/after:, filename:) | Power | M | Server and protocol core, client |
| Command palette and full keyboard navigation | Power, accessibility | M | Client shell and text messaging |
| Operator observability plus one-command backup, restore, and export CLI | Power | M | Administration and metrics, DevOps |
| Temporary member mute or timeout with auto-expiry | Community | S | Administration and moderation |
| Color-blind-safe redundant cues and an adjustable UI density setting | Accessibility | S | Foundations, design system |
| Webhooks, inbound and outbound, tightly scoped (inbound shipped, outbound not built) | Teams, power | M | Administration, extensibility |
| Tap-to-add: bring two phones together to swap an invite or open a DM | Community, owner idea | M | Client, after invites settle |

**Swept 2026-08-11, because "none are scheduled yet" above had stopped being true and a table of thirteen unbuilt features that is really a table of six is worse than no table.**
Rows left as they are rather than deleted, since the segment and sizing reasoning is still what a future contributor wants; what follows is what the tree actually says today.

Shipped, in whole or in the part that matters: pinned messages and personal saved items (migration 0060, `store/saved_messages.rs`, capped at 500 per user); in-chat polls; rich markdown and code blocks, hand-rolled rather than packaged, client 0.19.0; the command palette, on Ctrl/Cmd+K with the shortcut table bound into the shell; temporary member timeout with auto-expiry, which lapses by arithmetic at read time so nothing has to run on schedule; colour-blind-safe redundant cues (five presence states, five silhouettes, with a desaturation test proving it); the backup and restore half of the operator item, as `scripts/backup.py` and `scripts/restore-drill.py`; and the screen-share quality toggle, though not its audio capture.

Partly shipped: the density scale exists as `AppDensity`, but nothing selects a step yet, so the app reads `normal` everywhere and no density setting has shipped.
Partly shipped: per-user volume is built and works on three of six platforms for reasons `audio_gain.dart` records.
Push-to-talk and voice-activity sensitivity are built too, in Voice settings: push-to-talk is desktop only (`push_to_talk_listener.dart`), holds the mic closed until its key is held, and now joins a call closed rather than open-until-the-first-press.
Voice-activity sensitivity only moves the speaking-indicator threshold, never the SFU's own transmit decision; `passesActivationThreshold` records why it can narrow that decision but not invent one.

Not started, checked rather than assumed: low-bandwidth and data-saver mode, webhooks, and tap-to-add in any of its three shapes.

**Swept again 2026-09-02.** Two rows above had gone stale in the other direction - listed as unbuilt when the tree already had them - which is the expensive kind of stale, because it sends somebody to build a second copy.

- *Advanced search operators* are built. `http::search` parses `from:`, `in:`, `has:` and `before:`/`after:`, with `in:` and `from:` carrying an oracle-safety obligation the module documents; `tests/message_search/` splits its coverage along that same line. Only `filename:` from the original row is absent.
- *Message edit history* is built, both halves: `store::message_history` holds the revisions and `edit_history_sheet.dart` shows them behind the "(edited)" marker.

What that leaves genuinely unbuilt from this table: low-bandwidth/data-saver mode, ~~webhooks~~ (inbound shipped, see below; outbound is not built), `filename:` search, screen-share *audio* capture, and tap-to-add.

**Swept 2026-09-30.** Four entries below had shipped, and three of them were filed under "deliberately out of scope".
That is the kind of stale that sends nobody to build a second copy but tells a reader the product refused something it has.

- *Inbound webhooks* are built: `http/webhooks.rs` and `http/webhooks_admin.rs`, decision [0030](decisions/0030-incoming-webhooks.md), with a user page in [webhooks/pointing-tools-at-slim-m.md](webhooks/pointing-tools-at-slim-m.md).
  Outbound webhooks are not built.
- *Rich presence* is built: `PUT /presence/activity`, decision [0044](decisions/0044-rich-presence.md).
- *Slash-command registration* is built for bots: `http/bot_commands.rs`, decision [0031](decisions/0031-bot-command-registration.md).
- *Server-side link previews* are built as the opt-in this file asked for: off unless `SLIMM_LINK_PREVIEWS=true`, behind an SSRF guard, decision [0019](decisions/0019-link-unfurling-and-ssrf-defense.md).

### Tap-to-add, in more detail

Owner idea, 2026-07-28: the NameDrop gesture, where two iPhones held together glow and swap a contact, but for adding someone to a Space or opening a DM.

The appeal is that it removes the worst part of the current flow. An invite today is a code somebody has to read out, paste, or screenshot, and a code in a screenshot is a code in someone's camera roll forever. A gesture that hands one over in person expires the whole problem.

What it cannot be is NameDrop itself. That is Apple's own contact-exchange flow and there is no public API to hook an app into it: the glow, the haptics and the sheet all belong to the system, and an app cannot register a payload for it.

So the honest options, cheapest first:

- ~~**A QR code**, which works on every platform today, needs no entitlement, and is the thing people actually reach for. Show the invite as a QR, scan it to redeem. This is the one worth building, and it makes the rest optional.~~ **Dropped 2026-09-02**, on a premise this entry never checked: a QR is only worth anything if the URL inside it resolves, and nothing serves the web client (see `docs/OPEN-QUESTIONS.md` section 21). A QR pointing at the API domain opens a 404. What shipped instead is an invite *link* - `slimm://join?server=...&code=...`, built by the invites screen and absorbed by the redeem dialog on paste - which removes the same problem this entry was really about (a code read aloud, or screenshotted into somebody's camera roll forever) without needing anywhere to host it. Revisit the QR if the web client is ever served.
- **AirDrop**, on iOS, by exporting the invite as a file or URL. Real, supported, and a share sheet away, but it is a share sheet rather than a gesture.
- **Nearby Interaction plus MultipeerConnectivity**, iOS to iOS, which can genuinely do "hold them together" with UWB ranging. This is the closest to the idea and by far the most work: a second transport, its own pairing and trust story, and a permission prompt. Android's equivalent is Nearby Share, and the two do not talk to each other.

The trap to avoid is building the third one first because it is the exciting one. A cross-platform QR covers the same need on every device the product ships to, and if the gesture ever lands it is a nicer front end onto the same invite code.

One thing to settle before any of it: an invite handed over in person should probably be single-use and short-lived by default, which is a different default from the link you paste into a group chat. `POST /invites` already takes `max_uses` and `expires_at`, so that is a client decision rather than a server change.

Priority note: push-to-talk, per-user volume, and device switching are close to mandatory for anyone arriving from Discord voice, and they are nearly free on the existing media stack, so they should ride with the voice phase rather than being treated as optional later polish.

## Architectural hooks to preserve

These are not features to build now.
They are cheap decisions to make correctly now so an expensive retrofit is never needed.
Every relevant phase must honor them.

- Accessible Voice Canvas (most important): the canvas is an addressable semantic scene graph of typed objects (position, size, content, author, z-order) exposed to the accessibility tree and drivable by keyboard, never a pointer-only immediate-mode surface. The current per-object canvas model already satisfies this; keep it a hard requirement so blind and motor-disabled users are never excluded from the signature feature.
- Threaded replies: reserve a nullable parent-message reference and keep unread aggregation groupable by a scope key, so threads can layer on later.
- Bot and automation identity: keep the RBAC principal model able to represent a non-human actor, and keep the outbound event envelope stable and versioned, so a future automation API builds on the webhook principal rather than needing an auth retrofit.
- Custom emoji and stickers: reserve a custom-emoji reference format in message content and reactions, and plan to reuse the content-addressed attachment store.
- Guest and restricted-visibility accounts: give invites a scope field and confirm the RBAC overrides can express see-only-channel-X.
- Scheduled messages: do not bake a created-equals-now assumption into every write path, so a deferred-send job can assign the snowflake id at publish time.
- Temporary and auto-created voice rooms: reserve channel lifecycle fields (ephemeral flag, creator, time-to-live).
- Live captions and transcription: reserve a per-speaker timestamped text event on the call channel, and ship speech-to-text only as an optional module, never required for a lightweight self-host.
- Simultaneous multi-server identity: keep the client data store and connection layer keyed by server and keep push registration per server and device, so multi-account stays a later client-only change that preserves one-deployment-one-community.
- Cross-instance import and portability: keep the export format stable and documented and lean on the reserved snowflake node-id space for conflict handling.
- Localization and right-to-left: route every user-facing string through an i18n layer from day one and use logical start and end layout, so RTL is a later flip rather than a rewrite.

## Deliberately out of scope

Recorded so they are not re-litigated.
Each can be revisited if the product's direction changes, but the default answer is no.

- ~~Rich presence and game status:~~ Shipped, see decision [0044](decisions/0044-rich-presence.md), and see the 2026-09-30 sweep above. Original reasoning kept: per-OS process detection and a maintained games database is a privacy and upkeep burden that drifts into Discord-clone territory.
- Soundboard for short audio clips: clip storage, call mixing, and upload moderation is non-essential ritual against the not-a-clone principle.
- Heavy machine-learning noise suppression: a native DSP or ML dependency adds CPU cost while gaming; enable WebRTC's built-in echo cancellation and basic noise filter instead.
- Client plugin or scripting system: a heavy maintenance and security surface with no viable sideloaded-code story under App Store rules; webhooks and the future bot API are the sanctioned path.
  Note this is about code running inside the *app*, and does not cover server-side extensions an operator runs themselves; see [0007](decisions/0007-extensions-and-untrusted-execution.md).
- Running user-submitted code on the server as a built-in: declined 2026-08-03, because a built-in is opt-out per operator and this needs to be opt-in per install.
  Not declined as an idea - [0007](decisions/0007-extensions-and-untrusted-execution.md) records the extension-broker shape it would have to take, where the server brokers and never executes, an extension is always a separate process, and a marketplace is a directory an operator chooses from rather than anything that pushes code at a running deployment.
- ~~Slash-command registration framework:~~ Shipped for bots, see decision [0031](decisions/0031-bot-command-registration.md). Original reasoning kept: Slack-app-platform scope creep; the command palette and webhooks cover the real need.
- ~~Server-side link previews and URL unfurling:~~ Shipped as the opt-in, see decision [0019](decisions/0019-link-unfurling-and-ssrf-defense.md). Original reasoning kept: a lightweight self-host fetching arbitrary URLs can leak access to its internal network; only ever add as an opt-in, egress-sandboxed fetcher.
- Events with RSVP and a calendar subsystem: a real subsystem beyond chat; polls, pins, scheduled messages, and a webhook calendar integration cover the coordination need.
- Scheduled or recurring pings that store PII such as birthdays: recurring scheduler plus PII storage is bot-like scope creep that belongs in the automation API.
- Shared media gallery view: a non-essential convenience; because it is only a filtered query over the existing attachment store it can be added later at essentially zero design cost.

## From using it on a real device (2026-07-31)

Raised by the owner after real use, in his words where the wording matters.
Grouped by what they are rather than by where they were said, because three of them are the same underlying complaint about the message row.

### The message row

- ~~**Rows bounce on hover.**~~ Fixed in #251, released in client 0.18.0. The hover cluster is a `Positioned` child of a `Stack` in `MessageRow` now, so revealing it cannot reflow the transcript, and `message_row_hover_stability_test.dart` measures the row's height rather than inspecting the widget tree - asserting the button sits in a `Stack` would pass just as well if somebody put it back inside the `Column` within one.
  The original diagnosis, kept because the reasoning it replaced is worth not re-deriving: `ReactionsRow.build` need not re-find it: `ReactionsRow.build` (`client/packages/app/lib/src/widgets/message_row_parts.dart:83`) returns `SizedBox.shrink()` when a message has no reactions and is not hovered. Hovering therefore swaps absent-to-present rather than hidden-to-visible, and the row grows by the button's height, pushing everything below it.
  The current doc comment directly above that line argues for exactly this behaviour ("a permanent add-button under every message costs a row of vertical space each ... so the affordance belongs on hover with the row absent until then"). That reasoning is sound about the cost it names and is what produced the bounce, so the fix has to replace the argument rather than just the line: reserving the space instead would restore the very cost it avoids.
  The shape to copy is Discord's, which the owner named: a floating action cluster pinned top-right, in a `Stack`/`Positioned` inside `MessageRow` (the `builder: (context, hovered)` at `message_row.dart:144` already has the hover state), so it overlays rather than participating in layout. `ReactionsRow` then stops taking `showAddButton` entirely and renders only real reactions.
  Doing this also puts the affordance where the other two message-row items want to live, which is why these three should be one change rather than three.
- ~~**"as messages get long, the icons stay centered, they should align with the top of the text box like discord does"**~~ Settled 2026-07-31, and it turned out to be a third reading neither of the two below: the owner meant the **composer**'s own action icons, which sat centred against a growing input so they drifted down the screen as a message got longer. `composer.dart`'s action row is `CrossAxisAlignment.start` now. Released in client 0.18.0.
  The two readings that were recorded at the time, kept because the ambiguity is the point: this needed one word of clarification before anyone changes code, because the obvious reading does not survive checking.
  The *author avatar* is already top-aligned: `MessageRowLeading` (`client/packages/app/lib/src/widgets/message_row_identity.dart:109`) renders a fixed `_avatarSize` box, inside a `Row` that is already `crossAxisAlignment: CrossAxisAlignment.start` (`message_row.dart:181`). A long message does not centre it, so if that is what was meant, the bug is somewhere else and needs a screenshot.
  The likelier reading is the **hover action icons**, which is the same surface as the hover-reflow item above and would be fixed by the same overlay. Fixing that one is safe either way.
  Recorded rather than guessed at, because the two readings want opposite changes and shipping the wrong one is worse than asking.
- ~~**No way to highlight a message.** No selection, no jump-to, no visual mark.~~ Closed across #273 and #274, released in client 0.20.0. Jump-to and the visual mark went together, since a scroll with no mark leaves you at a wall of text not knowing which line you were sent to; search results, pinned messages and the quick switcher all navigate now, paging history in when the target is further back than what is loaded, and saying so plainly when it cannot be reached rather than scrolling to nowhere.
  Text selection is deliberately **desktop only**. `SelectionArea` claims press-and-drag, and on a phone that gesture already raises the message action sheet asked for two entries below; enabling it everywhere would trade a feature somebody asked for against one nobody did. The platform is the right question rather than the window width, since a narrow desktop window still has a mouse and a wide tablet layout still has no right button.
  Two things found on the way, both worth keeping. Tapping a pinned message or a palette hit would have thrown an uncaught `GoError`: both read the router from inside their own overlay, and `GoRouterState.of` does not resolve outside a route's builder subtree - the same shape as the `manage_channel_sheet.dart` bug already recorded, and caught only by writing a tap-through test rather than testing the callback in isolation. And a single jump to an estimated scroll offset undershot by **4.4x** on a long unevenly-sized list, because `ListView.builder` only knows the extent of what it has actually laid out.

### Composing

- ~~**No markdown or list formatting in any text field.** No way to type a list at all.~~ Fixed in #267, released in client 0.19.0. Bold, italic, strikethrough and spoilers inline; bullet and numbered lists, quotes and headings as blocks; Enter continues a list and ends it on an empty item; Ctrl/Cmd+B and I wrap the selection.
  Hand-rolled rather than taking a markdown package, and the reason is structural rather than taste: those packages render a whole document with their own theming and cannot produce the `WidgetSpan` mention chips, custom emoji images and design-system inline code that all predate this. The parser's own doc comment says so, to stop the next person "fixing" it by adding one.
  The risk was never the new syntax, it was every message already sent, so the false-positive cases carry the tests: `snake_case_name`, `2 * 3`, an opener with no closer, a `>` mid-line, a `#` with no space, and anything inside code. Mutating the parser found a real nesting bug (`*italic with **bold** inside*` mis-read the second `*` as a closer) and one test too weak to catch its own case.
- ~~**Ctrl+V does not attach an image.**~~ Fixed in #256, released in client 0.18.0, and honestly bounded rather than claimed closed: Flutter's own `ClipboardData` carries only `text` and its source says plain text is the only supported variant, so there is no cross-platform clipboard image to read. The web build hooks the browser's `paste` event, which hands over the bytes and needs no permission prompt (unlike `navigator.clipboard.read`). On desktop and mobile the file picker is still the only route, and the what's-new entry says so rather than implying otherwise.

### The rail and DMs

- ~~**"Notes to self" is treated as a channel under the hood and should be a DM.**~~ Fixed in #256, released in client 0.18.0. It renders as an ordinary DM titled **You** now, with its own kebab menu carrying a hide action; hiding it is a local preference rather than a delete, and searching your own name brings it back, which the empty state says in words so the route back is discoverable rather than folklore.
- ~~**The DM section is wordy**~~ Fixed in #243.
- ~~**No way to reorganise or move channels in the sidebar.**~~ ~~and no way to collapse the left sidebar entirely~~ - the collapse half shipped in #256 (client 0.18.0). Reordering closed on `feat/channel-ordering`: `channels.position` (dormant since `0002_core_schema.sql`, the `attachments`/`topic` shape) is now written by `PUT /channels/order`, deployment-wide rather than per-device (one deployment is one community, so everyone sees the same order), with drag-to-reorder in the rail behind MANAGE_CHANNELS and an optimistic client update that reverts visibly on failure.

### Voice and canvas

- ~~**The voice lobby screen has no purpose.** Owner's standing view, repeated: the join-preview screen is not earning its place.~~
  Acted on 2026-08-03 and struck here 2026-08-11: `d190a711` (PR #354) deleted the lobby, so clicking a voice channel joins directly.
  The roster this entry worried about losing survived in the rail, where `voiceRosterProvider` was already polling for it.
  [OPEN-QUESTIONS.md](OPEN-QUESTIONS.md) section 16 is the same item and was struck the same day, which is worth noticing on its own: two documents carried this as open for over a week after it was done.
- ~~**The pins button is styled differently from its neighbours**~~ Fixed in #242.
- **No background blur or replacement on camera**, which Discord has and which the owner calls "kindve a required feature" rather than a nice-to-have. Worth treating as a camera-launch blocker rather than polish: people will not turn a camera on in their own home without it. Note this is a real engineering item, not a setting - it needs a segmentation model running per frame on the local track before publish, so it lands with the camera work rather than after it.

### One open product question, not a task

The owner is thinking aloud about **canvas lifetime**, and it is not decided:

> perhaps if every docker server is just one "space" we could do a file browser or something, unsure how to handle canvases, like are they forever spaces, or is it like teams where every meeting is a new meeting and chat and the canvas changes after each meeting and is just an artifact or something, or should it persist for as long as the call exists, and people clear it as they need or save/export it as they need

Three candidate models, none chosen: a canvas that is permanent per channel (what ships today), one that is per-call and becomes an artifact afterwards, or one that lives as long as the call and is cleared or exported by hand.
This is a product decision with real schema consequences - `canvas_objects` is currently keyed per channel with no notion of a session - so it belongs in [OPEN-QUESTIONS.md](OPEN-QUESTIONS.md) rather than being resolved by whoever picks up the next canvas slice.

### A second round, 2026-07-31

- ~~**A what's-new screen on update.**~~ Fixed in #256 and #259, released in client 0.18.0. It carries one known weakness worth stating rather than discovering: nothing forces a contributor to add an entry, so a release can ship user-facing changes and show none of them. That caught us on the very first one - #256 shipped the screen with entries stopping at 0.17.2, so the first build ever to carry it would have had nothing to say about itself, and #259 was the fix.
- ~~**On mobile, the context menu should slide up from the bottom rather than float.**~~ Fixed in #256, released in client 0.18.0. The desktop path keeps its positioned overlay, its keyboard scope and its focus handling untouched, exactly as this entry asked.
  One trap found on the way, worth keeping: this entry named `ContextMenuRegion` as the widget to branch, and a first pass built the sheet there - on a widget nothing renders. The message rows go through `MessageContextMenuRegion`, and `ContextMenuRegion` had no call sites at all, so its own test suite passed while covering code that never ran. It is deleted now.
- ~~**Sending a message flashes a day divider.**~~
  Fixed 2026-08-01, and it needed the harness the previous entry's note asked for.
  "on sending a message it immediately puts a divider bar like the --today-- one and then deletes it."
  Partially diagnosed 2026-07-31, not fixed then, because the obvious mechanisms did not survive checking.
  `isNewDay` (`message_transcript.dart:280`) returned true whenever `previous == null`, so the oldest row in the window always carried a divider.
  But `watchChannel` windows at 200 and only evicts at that size, so an insert did not change which row was oldest in a shorter channel, and the optimistic row's ordering was also stable across the insert.
  Two tests confirmed that rather than reasoning about it: `channel_screen_day_divider_flash_test.dart` (seeded with same-day history, a gated send) and `message_store_predecessor_test.dart` (the store alone, no widget layer).
  Both stayed at exactly one divider throughout, ruling out both candidate mechanisms without finding the real one.
  The entry named what was left untried: a real `SyncController` catch-up landing between an optimistic send and that send's own REST response, or a live `message.created` echo racing the same response.
  Neither could be driven by any existing widget test, since every one of them substitutes `_NoopSyncController` for the real controller.
  **`client/packages/app/test/support/sync_harness.dart` is that missing piece.**
  `SyncTestServer` binds a real loopback `HttpServer` and accepts the WebSocket handshake `SyncController._attach` performs; REST stays mocked through a `RestRouter`, which `MockClient` answers directly.
  Both pieces are generic to any live-versus-local interleaving, not specific to this bug.
  **The catch-up race reproduced, on the first mechanism named.**
  `channel_screen_day_divider_sync_race_test.dart` seeds *no* local history (a device that has never synced this channel), gates `/sync` behind a `Completer`, and sends while it is still gated.
  The pending message is the sole loaded row, so `isNewDay`'s `previous == null` branch anchors a divider on it - correctly, given what is known so far.
  Releasing the gate lands two earlier same-day messages ahead of it in one atomic store write, and the divider that had been on the sent message is gone, replaced by one on the row that is now oldest.
  Mutation-tested: reverting the fix below reproduces the exact flash, frame by frame.
  **The live-echo race did not reproduce, checked rather than assumed.**
  `channel_screen_day_divider_live_echo_race_test.dart` pushes the server's own `message.created` echo of the just-sent message down a real socket before that message's REST response resolves, and the divider never moves.
  `MessageStore.applyMessage` is idempotent and route-agnostic, so which delivery path lands first changes nothing about `previous` for day-divider purposes.
  Recorded as ruled out rather than deleted, since a future contributor re-suspecting it now has a working way to check.
  **The fix**: `isNewDay`'s `previous == null` anchor - "the oldest loaded row also counts, anchoring the top of the transcript with the day it began" - is only trustworthy once this session's first catch-up round has actually completed.
  Before that, the oldest loaded row is oldest only because nothing else has landed *yet*.
  `initialSyncCompleteProvider` (`sync_controller.dart`) is a `StateProvider<bool>` set true once inside `SyncController.start`, right after `_catchUp` returns and before `_attach`, deliberately independent of whether the live socket then connects.
  Unlike `SyncStatus`, which drops back to `connecting`/`offline` on every later reconnect, this only needs to become true once and stay true for the session, since a reconnect's catch-up can only confirm history already known, never un-confirm it.
  `MessageTranscript.historyKnown` threads it down to `isNewDay`; `channel_screen.dart` reads the provider alongside `syncStatus`.
  Reset on sign-out (`_endSession`) alongside the other per-session providers there.
  **Setting it from a test's `_NoopSyncController` needs a real `await` first, not just an override.**
  Riverpod refuses a provider modifying another provider during initialization ("Providers are not allowed to modify other providers" - found by trying it in the constructor and hitting that assertion), and the base `SyncController` constructor calls `unawaited(start())` synchronously, so an override with no `await` before the write runs inside that same initialization window.
  The real `start()` clears this for free, since `_teardown`'s own await comes first; `_NoopSyncController.start` needs one explicit `await Future<void>.value();` before the write, which is exactly what let `channel_screen_day_divider_flash_test.dart` keep asserting its one real divider.
  **A real `HttpServer` inside a widget test's fake-time zone hangs the test's shutdown for a fixed ~90 seconds**, then crashes with "Cannot close sink while adding stream" rather than failing cleanly - a new instance of the same class of trap as `RenderRepaintBoundary.toImage()` needing `tester.runAsync` (see the Fedora-build entry in this knowledge base).
  `HttpServer.bind`'s own periodic idle-timeout timer is captured as a `FakeTimer` when created inside the fake zone, and the test binding's shutdown waits on it for real wall-clock time before giving up.
  Both `SyncTestServer.start` and `.close` must be called through `tester.runAsync`; the fix is recorded on the class itself so the next caller does not rediscover it by hanging.
- ~~**Two channels overlay each other while switching.**~~ Fixed in #253: `fadeThroughPage` was a cross-fade, not a fade-through - it faded the incoming pane in while the outgoing sat at full opacity, so both were legible at once.
- ~~**One image fills the desktop.**~~ Fixed in #253: the inline preview was capped at the full message column on width and had no height bound at all, so a tall image took the screen. `kInlineImageMax` is half the column on both axes.

### ~~A frameless window with our own title bar~~ (built 2026-08-10, struck 2026-08-11)

**Built, not deferred.** [decision 0012](decisions/0012-desktop-window-shell.md) is the design and PR #533 is the build, with a no-tray quit gap closed on 2026-08-11.
It turned out to be one subject with two other owner asks - a startup animation into last-known geometry, and closing to a tray rather than quitting - because all three need the app to own its own window lifecycle rather than the OS owning it.
`desktop_window_shell.dart`, `desktop_chrome.dart` and `desktop_window_port.dart` are the client side.
The per-platform split this entry worried about is exactly what shipped: macOS runs frameless keeping the native traffic lights top-left, Windows and Linux draw their own controls and close to a tray.
The tray entry is also what made the flatpak need `libayatana-appindicator3` vendored into it, which is a cost this entry did not foresee and PR #552 paid.

The original entry follows, kept because the trade-offs it names are what the decision record had to answer.

The owner asked whether the OS title bar can be replaced with a compact custom one the way Discord does.
The answer is yes and it is worth doing, deliberately deferred rather than declined.

**What it buys:** the desktop currently stacks the OS title bar above the channel header, two bars where Discord has one.
On a laptop that is real vertical space.

**What it costs:** window dragging, double-click-to-maximise, edge snapping and the system menu all have to be reimplemented, and they are easy to do badly.
Three platforms want three different things: macOS traffic lights top-left with specific insets, Windows controls top-right, Linux depending on the desktop environment.
A single custom bar that ignores that feels foreign on at least two of them.
Window controls also have to stay reachable by keyboard and to a screen reader, which the OS provides for free.

Note that on Wayland, which is this project's Linux target, client-side decorations are already the norm, so this fits the platform rather than fighting it.

**A separate, smaller bug found alongside it, and fixed here since it was a one-liner.**
The Linux window title read `slimm_app`, the binary name, rather than `slim-m`.
iOS, Android and the web build all already show `slim-m` (`CFBundleDisplayName`, `android:label`, and the web `<title>`); only `client/packages/app/linux/runner/my_application.cc` had never been updated to match, in both the GNOME header-bar branch and the plain-titlebar branch.
Fixed to `slim-m` in both places.
~~Neither branch reads the current Space name: that would need a runtime Dart-to-native bridge that does not exist yet, so it is out of scope for a one-liner and belongs with the frameless-window work above if it is ever built.~~
Half stale, corrected 2026-08-11: the frameless-window work above did get built, and it brought `window_manager` with it, so the bridge this said does not exist is `desktop_window_port.dart` and a window title is one call away now.
Still true is that nothing sets it to the Space name; the C++ default is what a native title bar would show, and on Windows and Linux the app hides that bar anyway.

## Multiple spaces within one deployment

Owner concern, raised 2026-08-18.
Recorded for later consideration only; no design or feasibility work has been done, and none was asked for.

The current model is one deployment (one Docker container) is one community, locked in `docs/decisions/0001-owner-decisions.md` and stated in `CLAUDE.md`.

The concern is whether that one-community-per-container shape should stay that way.
A person may belong to several unrelated communities at once: the owner's own examples were being in a Dungeon Defenders community, keeping school friends in a separate one, and keeping Counter-Strike friends in a third.
Under the current model each of those is a separate deployment the person joins separately, rather than several communities reachable from one place.

The rough direction floated, not a design: perhaps a user could create their own "space" within a single container, so one deployment could host more than one community.

This is left as a raised question against decision 0001 rather than an accepted feature, because it changes a founding constraint rather than adding on top of it.
It is not scheduled and it is not to be acted on until the owner decides to.
