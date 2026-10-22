# The end-to-end harness

`scripts/e2e.sh` stands a whole deployment up, drives two clients through the
product, and tears it down.
Nothing in it is mocked: a real LiveKit SFU, the release server binary, the real
web build, and two isolated headless browsers that talk to each other.

```bash
bash scripts/e2e.sh            # the whole run, then teardown
bash scripts/e2e.sh --keep     # leave the stack up afterwards to poke at
E2E_ONLY="reaction" bash scripts/e2e.sh   # one scenario, by name
E2E_ONLY="reaction|reconcile" bash scripts/e2e.sh   # several, split by |
E2E_REBUILD=1 bash scripts/e2e.sh   # rebuild the web bundle first
```

It needs docker, flutter, cargo, python3 with `websocket-client`, and a system
Chrome.
Screenshots land in `/tmp/e2e/shots`, one per interesting moment, and are
worth looking at after a failure: the harness writes one at the point it gives
up as well, with the browser's console log beside it under the same name.

Two of the files the web build needs at runtime are gitignored binaries, so the
script fetches them itself (`client/packages/app/tool/fetch_web_assets.sh`, a
no-op once they are present) and then checks the running static server actually
answers for each of them.
That check is worth its lines: without `sqlite3.wasm` the app signs in, loads
the member pane, and renders nothing but "Could not load channels." with sync
stuck offline, which reaches the harness only as a channel row that never
appears. See "Reading a red run" below.

It also runs in CI now, as `.github/workflows/e2e.yml`: on every push to `main`, on a nightly schedule, and by hand through `workflow_dispatch`.
It is advisory rather than required while it proves itself out; see `docs/ci.md` for the trigger reasoning and the promotion path.
Before that workflow existed this script ran nowhere and its failures went unnoticed for a real stretch of time, which is the reason it exists.

## What it checks, and against what

Every scenario drives the UI the way a person would and then asks the **server**
whether it happened.
That second half is the point.
A reaction chip that renders, a roster that fills, an avatar that appears: none
of those are evidence that anything was stored, and a client that only ever
agrees with itself would pass a run in which nothing was persisted at all.
The voice scenarios go further and ask the SFU directly, because a participant
tile is not a published track.

| Scenario | Driven through | Checked against |
| --- | --- | --- |
| sign-in, fingerprint, invite gate | the UI | the server's own session |
| a message each way | the UI | `GET /channels/{id}/messages` |
| a mention | the UI | the stored message text, verbatim |
| a reaction | the UI, through the picker | the message's `reactions` |
| an attachment | the UI, through the file picker | the message's `attachments` |
| a profile picture | the UI | `GET /users/{id}/avatar`, byte length |
| theme and status | the UI | the control's own reported state |
| personal vs Space settings | the UI | that neither shows the other's rows |
| who can join | the UI | `/space/settings` and `/version` |
| creating a role | the UI | `GET /roles` |
| a reply, and a reply to a deleted message | the UI (the send and the delete go over the API; see below) | `reply_to_id` stored, the quote naming its parent live, and the honest jump-failure notice once it is gone |
| a thread stays off the ordinary channel list | opening it is the API (see below), reading and replying is the UI | the channel list excludes it, and the parent message's own reply-count affordance |
| reporting, blocking | the API (see below) | the moderation queue, the block list |
| the capability handshake | the API | that `/version` names the two routes the run just used |
| permissions | the API | that a member is refused and an admin is not |
| a voice call, mute, leaving | the UI | the SFU's participant and track list |
| sharing a screen | the UI | a `SCREEN_SHARE` track on the SFU |
| the canvas dock keeps a call's own controls reachable | the UI | mute and unmute, clicked from inside the canvas's own dock, both reach the SFU |
| a shared camera tile: two drags, a live update on the peer, a call rejoin, a cold canvas reopen | the UI (`e2e_media_slots.py`) | `GET /channels/{id}/canvas/media-slots`, and the peer's own screen position, twice over |
| re-clicking a voice channel already left rejoins it | the UI | the SFU's participant list, ACTIVE with a published mic |
| calling in a DM | the UI | the SFU's participant and track list, keyed by the DM's own channel id |
| edit, delete, search, pins, polls, invites, DMs, channel admin, devices, read state, sync | the API | the effect of each, not its status code |
| the Voice Canvas: draw, paste an image, place a note and a shape, move, resize, reorder, erase, clear, undo, reload | the UI (`e2e_canvas.py`, `e2e_canvas_shapes.py`; see below) | `GET /channels/{id}/canvas/objects`, `z_index` for the reorder, and the second client's own `performance` resource log for the pasted image's bytes |
| placing a shape selects it and arms Move, with no manual tool switch | the UI | a drag right after placing moves the object rather than adding a second one |

The run ends by reporting how many documented API paths it actually touched,
counted from what the harness and both browsers requested rather than from a
list kept by hand, since a hand-kept list overstates coverage the moment a
scenario changes. ~~A full run currently reaches **43 of 72** documented paths
(confirmed against a live run rather than assumed; the schema has grown
since this number was first written, the harness's own reach has grown with it).~~
Stale as of 2026-08-11 by exactly the mechanism the parenthetical above already
warned about: the schema grew two more paths (`/channels/{channelId}/permissions`
and `/channels/{channelId}/thread-parent`, both from decision 0011) after this
number was last written on 2026-08-08, and nobody re-ran the harness in between
to catch it. A fresh full run today reaches **44 of 74** documented paths (59%),
which is the number to trust; this line will drift again the next time the
schema or the harness's own reach moves and nobody happens to rerun it, which
is exactly why the run prints its own count rather than this doc being the
record of it.

What it does not reach divides into two: routes that need a second
deployment or real hardware (push, the relay lifecycle, account recovery),
and routes that are simply not covered yet (per-channel overwrites, assigning
a role to a member, kicking someone from a call, revoking one device, custom
emoji, redeeming a second invite, space analytics). The Voice Canvas closed
the third category this file used to name here; see "Driving a canvas app"
below for what that took. The remaining group is the honest backlog; the run
prints it every time so it cannot quietly grow.

## Layout

| File | What it owns |
| --- | --- |
| `scripts/e2e.sh` | the stack: SFU, server, web build, two browsers, teardown |
| `lib/e2e_run.py` | the running order, and the coverage report at the end |
| `lib/e2e_client.py` | one browser, over the Chrome DevTools Protocol |
| `lib/e2e_js.py` | the browser-side half: reading and driving the semantics tree |
| `lib/e2e_input.py` | real pointer and key input: right-click, hold, Tab, Shift+Enter |
| `lib/e2e_labels.py` | every accessible name the app is driven by, in one place |
| `lib/e2e_api.py` | the server's own answer, for checking against |
| `lib/e2e_messaging.py`, `e2e_settings.py`, `e2e_admin.py`, `e2e_voice.py`, `e2e_voice_rejoin.py`, `e2e_markdown.py`, `e2e_reconcile.py`, `e2e_replies.py`, `e2e_threads.py`, `e2e_message_menu.py`, `e2e_composer.py`, `e2e_members.py`, `e2e_accounts.py`, `e2e_dm_call.py`, `e2e_canvas.py`, `e2e_canvas_shapes.py`, `e2e_media_slots.py`, `e2e_voice_noise.py`, `e2e_voice_volume.py`, `e2e_voice_devices.py`, `e2e_voice_deafen.py`, `e2e_voice_share.py`, `e2e_voice_multishare.py` | the scenarios |
| `lib/e2e_audio.py`, `e2e_audio_js.py`, `e2e_audio_levels.py`, `e2e_browsers.py`, `e2e_voice_ui.py` | the voice probe, its maths, extra browsers, and the call-surface helpers (see Measured voice) |
| `lib/e2e_sweep.py` | the API-level routes the scenarios do not reach |
| `lib/e2e_seed.py`, `e2e_fixtures.py` | the accounts and the two PNGs a run uploads |

Labels live in one module because they are a contract with the UI rather than
incidental strings: when one changes, exactly one line changes with it.

## Measured voice

Six scenarios judge voice by what a listener would hear and see, not by what a widget says.
They live in `lib/e2e_voice_noise.py`, `e2e_voice_volume.py`, `e2e_voice_devices.py`, `e2e_voice_deafen.py`, `e2e_voice_share.py` and `e2e_voice_multishare.py`.

`lib/e2e_audio_js.py` holds an in-page probe.
`lib/e2e_audio.py` installs it with `Page.addScriptToEvaluateOnNewDocument` and reloads the page, so it sees the app's own `AudioContext` and `RTCPeerConnection`.
For each remote audio element it samples every 50 ms, in two places: the stream as it arrives, and the output after the app's own gain graph (or after the element's mute and volume when the app has spliced in no graph).
Comparing the two in the same window gives the gain the app applied, which cancels the sender's own level drift.
`lib/e2e_audio_levels.py` is the plain maths (dB, percentiles, applied gain, leak, longest gap) and has its own unit tests.

Chrome's fake microphone plays a WAV given with `--use-file-for-fake-audio-capture`.
`make_fake_voice.py` writes the speech-shaped one every browser captures.
`make_noisy_voice.py` writes a seeded speech-over-steady-noise one for the suppression scenario.
A scenario that needs a third person, or a different WAV, starts its own browser through `lib/e2e_browsers.py` on ports 9811-9814 and always kills it again.

| Scenario | Measured at the listener | Bounds |
| --- | --- | --- |
| noise suppression | alice listens to two senders playing the same noisy WAV, one the app untouched and one with only the browser's noise suppression refused; the noise-only floor and the speech level of each | the floor is at least 10 dB lower and the speech at most 3 dB lower with suppression; measured 17 dB and 0.3 dB |
| a listener's volume slider | the gain applied to bob's stream at 100%, 47% and 0%, and again after leaving and rejoining | within 1.5 dB of the slider's own dB, nothing at all leaks at 0%, and 0% survives a rejoin |
| picking a microphone | the published track's `deviceId` and label read off the sender, and the peer's longest silence | the track changes, the choice survives a rejoin, and the peer never loses bob for more than 1.5 s; measured 0.2 s |
| deafening | bob's own playback of alice, and alice's of bob | deafened bob hears silence, alice still hears bob, undeafening restores it |
| a share's own volume | bob's share is given a steady tone; the screen-audio stream and the voice stream are measured apart | the stream slider moves only the screen, the voice slider only the voice |
| two shares at once | decoded frames and mean luminance of every `<video>` on three pages | carol decodes both, focusing enlarges one, showing all restores both, and stopping one leaves the other |

The web client has the browser's noise suppression only.
The rnnoise "Strong" mode is a native desktop capture chain and is measured natively, not here.
Push-to-talk is a desktop-only control and does not exist on the web build, so no scenario here can hold a key; its gate is covered by the client's own unit tests.
Mute and the speaking ring already had scenarios (`mute_actually_silences`, `audio_actually_arrives`), so they are not repeated.

The thresholds come from measured runs, and each scenario prints the numbers it measured, so a later change to a bound is a judgement against data.
A screen share has no system audio in a headless browser, so the sharer's `getDisplayMedia` is wrapped to add a tone as the share's audio track; the app then publishes and plays it as it would a tab's sound.

Run one of them on its own, inside the shared lock (several agents use this machine, and `scripts/e2e.sh` owns fixed ports):

```bash
E2E_REBUILD=1 E2E_ONLY="volume slider" flock ~/.slimm-scratch/tmp/e2e.lock scripts/e2e.sh
E2E_ONLY="noise suppression|deafening" scripts/e2e.sh    # several, split by |
```

`E2E_ONLY` matches a fragment of the scenario's name, so `noise suppression`, `volume slider`, `picking a microphone`, `deafening`, `share's own volume` and `two shares at once` each pick one.
Leave `E2E_REBUILD` off to reuse the last web build, and set it after any client change.
Each scenario joins its own call and leaves it, so any of them runs alone.
Added to a full run they cost about eight minutes: the noise scenario about two (it signs two more accounts into two more browsers), the share volume and two-share scenarios a minute and a half each, the volume slider and microphone scenarios a minute each, and deafening about forty seconds.

## Driving a canvas app

Flutter paints to a canvas and exposes nothing to a script until its
accessibility tree is on; one click on the placeholder it leaves in the DOM
turns every widget into an `<flt-semantics>` element with a real bounding box.
That is what makes this label-driven rather than pixel-driven, so a layout
change does not break it.

Four things cost real time to learn, and each fails silently rather than loudly:

- **Only the focused text field has an `<input>`.** Every other field on screen
  is paint, so a field is clicked once to bring its element into being, then
  focused by `aria-label` rather than clicked at coordinates.
- **The same label is painted onto a plain node and a tappable one**, and only
  the one carrying `flt-tappable` answers a click. The closest name wins, too:
  a channel row and its "Manage <name>" button both match the channel's name,
  and taking the last match opened the manage sheet every time. Two tappable
  matches with neither an exact name is resolved by nesting, not just length:
  a reply's quote button renders its own accessible label as inline text
  rather than an `aria-label` attribute, so its derived name is that text
  glued to its rendered snippet, which came out longer than the message row
  enclosing it - "shorter wins" then picked the row over the button it
  contained. A tappable node nested inside another tappable match is always
  the more specific one, so containment is checked before length.
- **The file picker's `<input>` never enters the document.** Flutter builds it,
  clicks it, and drops it, so there is nothing for `DOM.setFileInputFiles` to
  find; `createElement` is wrapped to catch it, and it is handed a real `File`
  through a `DataTransfer`.
- **Pointer events do not reach the canvas while the tree is on**, because the
  semantics elements sit over it. `gestures(True)` lifts them for the
  affordances that have no label - the react button, which only exists while
  the pointer is over a message, and the message menu, a held reaction chip and
  Tab in the composer, which `e2e_input.py` drives with genuine browser events.

### Driving the Voice Canvas specifically

The signature feature is a `CustomPainter`, so it publishes almost nothing
else to the tree beyond what the general rules above already cover. Two more
things `e2e_canvas.py` and `e2e_canvas_shapes.py` (note, shape, reorder -
split out to stay under the file budget) lean on, documented at length in
`e2e_canvas.py`'s own module doc:

- **The one container `Semantics` node whose label starts "Canvas,"** states
  the live object count ("Canvas, 2 objects: 1 stroke, 1 image") and updates
  on every local and live change, so it is the main proof both clients agree
  without ever opening anything else. Its own bounding rect is also the
  coordinate frame every drawing and dragging gesture is placed in, since the
  camera starts at world `(0, 0)` with `zoom: 1` and this scenario never pans
  or zooms - a page coordinate and a world coordinate differ by exactly one
  constant offset for the whole scenario. A note or a shape is placed at a
  *fraction* of that rect's own live width and height rather than a fixed
  offset, because both run after the pasted image has already been dragged
  and resized once and a blind fixed offset risks landing on top of it.
- **`CanvasActivityPanel`, the text activity log**, is reached for what the
  object count cannot show: that a move, a resize, or a reorder actually
  arrived on the client that did not make it, not only that the server's own
  row changed. It replaces the drawing surface while open, so it is toggled
  on, read, and toggled back off rather than left open.

Drawing, moving, resizing, reordering and placing a note or shape all still
need `gestures(True)` and raw pointer events, the same as the react button -
a note or a shape places on pointer-down alone, so a one-point `drag()` call
is a real tap; the pasted image goes through the same `paste` DOM event a
real Ctrl+V produces (`e2e_js.paste_image`), not the API, because the bug
this scenario exists to catch was a client-side hydration gap that calling
the API directly would never have exercised.

**Not covered, deliberately: the in-flight stroke preview** a second client
sees while the first is still drawing (`canvas_stroke_preview_relay.dart`).
It paints through a second `CustomPainter` with nothing in the accessibility
tree at all, not even during the gesture, so proving a frame reached the
other browser mid-draw would need either a pixel comparison (this harness is
label-driven by design) or sniffing the receiving browser's own WebSocket
traffic over CDP, which would only prove a frame arrived, not that it
painted anything. `draw_stroke_and_see_it_live` already checks the *result*
of a draw on both clients; the preview itself is named here as an honest gap
rather than a test that would pass whether or not it worked.

### Driving a shared camera or screen-share tile

`e2e_media_slots.py` is the one canvas scenario whose entire claim is that
two clients agree about something neither of them drew: a camera or
screen-share tile's position, size, lock and depth are shared and
server-persisted (decision 0010's reversal), not a purely local presence
artifact the way the tile's video itself is. `CanvasPresenceManipulableTile`
carries a container `Semantics` node too - `"<name>, on this call's
canvas"`, or `"<name>, you, ..."` for the caller's own tile
(`canvas_presence_layer.dart`'s own `_tile`) - findable and draggable the
same way the drawing surface's own object handles are, with the same
`gestures(True)`/raw-pointer requirement, since it sits over `CanvasSurface`
too. Two things this scenario checks that no unit test on either side can:
the second client's own on-screen tile position moves, live, after the
first drags theirs (proving the `canvas.media_slot.changed` frame actually
reached and repainted a second client, not only that the server's own row
changed); and a *cold* reopen of the canvas pane - which reconstructs
`CanvasPresenceTileOverrides` from scratch, dropping every local override -
still finds the tile exactly where it was left, which only the server's own
persisted row could answer from.

**A canvas viewer sees no presence tile at all for a call they have not
themselves joined**, even for a channel whose canvas they can otherwise
read and draw on: `canvas_pane_gestures.dart`'s own `_callParticipants`
answers empty unless `voiceControllerProvider.channelId` matches the pane's
own channel, since there is no LiveKit room to render a live texture from
otherwise. So this scenario opens `b`'s own canvas from the same voice
channel's wide header, mid-call, rather than reusing whichever canvas
`b` already had open on the text channel earlier in the run.

**A tile showing a live camera track cannot be dragged this way, and it
fails silently rather than loudly.** First written to toggle the camera on
before dragging; the drag consistently left the tile at the exact pixel it
started, confirmed with a screenshot before and after. `presenceTileKeys`
(`canvas_presence_geometry.dart`) gives every call participant a
`camera:<id>` tile the instant they join, camera on or off, rendered as a
plain avatar bubble - real canvas-painted content - until the camera
actually turns on, at which point flutter_webrtc's web `RTCVideoView`
takes over as an `HtmlElementView` platform view, a genuine interactive DOM
`<video>` element layered over Flutter's own canvas. A raw CDP mouse event
lands on that element and never reaches Flutter's gesture arena at all. The
scenario never turns the camera on, since the feature under test - shared,
persistent position, size, lock and depth - is identical either way, and
the avatar bubble is real Flutter canvas the same drag mechanism already
works against everywhere else in this file.

**Not covered, deliberately: whether the dock's own controls are reachable
by touch at a narrow width**, the class of bug #460's own commit message
names (an overflow menu that opened off-screen until it learned to open
upward, caught by a widget test rather than by a person). `e2e_js.click`
finds a labelled control and calls `.click()` on the DOM element directly;
that fires the framework's own tap handler regardless of whether the
element is actually visible or covered, so a scenario built the same way -
launch a browser at a phone width, click every dock label, assert each is
found - would pass whether or not a real thumb could reach it, which is the
class of false pass this file's own touch-reach tests were written against
once already (see this file's own history, and `CLAUDE.md`'s canvas
entries). `canvas_call_dock_touch_reach_test.dart` and
`canvas_tools_row_touch_reach_test.dart` are the real check: both drive
`tester.tap(..., warnIfMissed: false)`, Flutter's own hit-test, at 320
logical pixels, and assert a clipped control is unreachable until a real
drag reveals it. Widening this harness's browsers to a second, narrower
size would only add a scenario that cannot tell "found" from "reachable" -
an honest gap declined for the same reason the stroke preview above is.

## Running it in parallel

`scripts/e2e-parallel.sh` runs the same scenarios as `scripts/e2e.sh` on several stacks at once.
It builds the server and the web client once, then starts one `scripts/e2e.sh` per shard with its own `E2E_API_PORT`, `E2E_WEB_PORT`, `E2E_LK_PORT`, `E2E_RTC_*`, `E2E_CDP_BASE`, `E2E_LK_CONTAINER` and `E2E_WORK`.
The shards use ports from 28100 up (browsers from 29000), clear of the serial defaults, so a stack someone is using by hand is left alone.

A scenario that leans on what an earlier one left behind runs on the same stack as it, in the same order.
`scripts/lib/e2e_groups.py` names those groups (`text`, `settings`, `admin`, `canvas`, `call`, `dm-call`), and every other scenario is its own group.
Groups are dealt longest first to the emptiest stack, using the measured seconds in `scripts/lib/e2e_durations.json`.
After a run that changes how long things take, `--record` rewrites that file from the passes.
A new scenario that needs state from another goes in that scenario's group; one that does not needs no entry.

Each shard writes `E2E_RESULTS`, a JSON list of name, outcome and seconds, and the runner merges them into one report with the slowest scenarios and a non-zero exit if any scenario failed or never reported.
Each shard's full log is `shard-N.log` in `E2E_PAR_WORK` (default `~/.cache/slimm-e2e/par`).
`E2E_ONLY_FILE` selects scenarios by exact name from a JSON list, which is how a shard is given its share; `E2E_ONLY` still works for a fragment.

## How the client waits

`Client.click` and `Client.settle` wait for the accessibility tree to stop changing rather than sleeping a fixed time, with the old time as the ceiling.
A pause that waits on something the tree never shows, such as a video track winding down before a decoding check, passes `fixed=True`.
`E2E_FIXED_SETTLE=1` restores fixed sleeps everywhere, which is the first thing to try when a scenario is flaky and the cause is not clear.
Polls re-read the tree every 250 ms.
The canvas board's position is read off the pixels (`e2e_board_frame.board_frame`), not derived from where other controls sit.

## What it drives at the API, on purpose

Reporting and blocking live behind the message context menu, and are still
driven at the API: `scripts/lib/e2e_admin.py` says so in its docstring rather
than implying the UI path was exercised.
That menu used to be unreachable here, since a click dispatched at a semantics
element does not open it.
A genuine right-click sent with the semantics layer lifted does (see
`e2e_input.py`), which is how `e2e_message_menu.py` drives its quick reactions
and More page and how `e2e_threads.py` opens a thread with "Reply in thread".
Sending a reply is still a substitution, made in `e2e_replies.py`.
The menu is also reachable from a keyboard (the context-menu key), and a screen
reader reaches it through the long-press action a test guards.

Permissions are checked at the API deliberately rather than reluctantly.
Hiding a button is not access control; refusing the request is, and each body
sent is one an administrator would succeed with, so the only thing left to
explain a refusal is the caller.

## Reading a red run

Every scenario that needs a rendered channel fails the same way - a label that
never appeared - whatever the real cause was, because a browser gives a script
no other symptom.
So the first red run on a GitHub runner (30565517095) came back as nine
failures cascading from the first messaging one, and the screenshot showed a
signed-in client with a full member pane, an empty rail reading "Could not load
channels.", and the connection bar reading "Offline, retrying."

That is one cause, not two: the rail renders from the local database and sync
cannot start without it, so both die together when `WasmDatabase.open` throws.
It threw because `sqlite3.wasm` and `drift_worker.js` are gitignored and had
never been fetched on that runner, while every checkout here has had them since
before the workflow existed.
Sign-in, `/users` and the settings screens all kept working throughout, which is
why the run looked like a messaging bug rather than a missing file.

Three things came out of that and are worth knowing when the next one goes red:

- The harness fetches those two files and refuses to run if the served origin
  does not answer for them, so this particular failure is now a named refusal in
  the first few seconds rather than nine timeouts twelve minutes in. That check
  caught a second thing on its first run: `flutter build web` copies `web/` into
  `build/web` once and never re-syncs a file that turns up in `web/` afterwards,
  so `E2E_REBUILD` removes `build/web` before building.
- It refuses to start if something is already listening on the web port. A
  second server answers with a build this run did not compile, which is exactly
  what would have hidden the fault from a local reproduction. That refusal found
  where the stale ones came from: the static server ran inside a subshell, so
  teardown killed the wrapper and orphaned the server. It has no subshell now.
- The browser's own log is written beside each failure screenshot, and the
  workflow uploads the server log with them. The 404s were the whole answer here
  and nothing was capturing them.

## What it found

Running it against the real product, rather than reasoning about it, turned up
two defects nothing else had.

The avatar crop sheet sized its square viewport from the window's width alone,
so on any window wider than it is tall - which is every desktop - the circle
was taller than the screen and pushed Cancel and Use picture off the bottom.
There was no way to finish or abandon a crop, and so no way to set an avatar at
all. Fixed, with a test that asserts both buttons sit inside the window at
three sizes.

The message context menu looked unreachable without a pointer. It has since
gained a keyboard route, and a real right-click reaches it here.

Driving the Voice Canvas for the first time found two more, neither of which
any widget test had caught, because neither needed a widget test to be wrong -
they needed two clients, or a client that never moved its camera.

Pasting an image onto the canvas did nothing, silently, whenever the composer
had ever held focus in the same session (which is every real session, since
signing in lands on a channel with a composer already there). Both the
composer and the canvas share one module-level "who is listening for a
paste" variable with no notion of ownership, and the composer's own
`dispose()` calls `stopClipboardImagePaste()` unconditionally; if that call
lands *after* the canvas's own `start()` already took over - which a fade
transition makes likely, not just possible - it tore down the canvas's
listener instead of its own. `stopClipboardImagePaste` now takes the same
callback `start` was given and only tears down while it is still the
registered one.

Undoing an erase or a clear did nothing visible on the client that clicked
Undo, unless that client happened to pan the camera afterward. The object
comes back server-side immediately - confirmed by reading `GET
.../canvas/ops` directly - but the client deliberately never re-materializes
a restored object's payload locally (it was freed on removal), and the
camera-move guard that would otherwise re-fetch it only runs when the view
actually changes. A full reload "fixed" it in testing only because a fresh
pane's very first camera-moved call always cold-fetches regardless of that
guard, which is what made this easy to not notice. Both `CanvasSync`'s
catch-up path and the live dispatch's `CanvasObjectsRestored` case now
force an explicit re-fetch alongside forgetting the tombstone.

## What it does not cover

The mobile clients, push notifications, search, polls, pinning,
invites beyond the one the seed spends, and message edit and delete.
Those are honest gaps rather than assumed-working: the run reports only what it
checked.
