# The soak harness

`client/packages/app/test/soak/` runs hours of a signed-in desktop session in a few minutes and reports what the app is still holding at the end.
It exists for the person who leaves the app open for days, in a big community, signed into several servers.

It is a widget test.
The app is the real one: the real root, router, shell and account host, with one provider container per account.
The clock is the test's fake clock, so ten simulated minutes cost about ten real seconds.
The server is a fake community per account (`soak_world.dart`): 40 text channels, 6 voice channels, 8 DMs and 500 members, answering the REST calls the shell makes.
Live frames go in through `SoakSyncController.deliver`, which broadcasts and applies each frame the way the real socket listener does.
The call is a recording fake, so no LiveKit is involved.

## Running it

```bash
cd client/packages/app

# The smoke run. It is part of the ordinary test suite and takes about 15 seconds.
flutter test test/soak/long_session_soak_test.dart

# Twelve simulated hours, with heap counts, in about 17 minutes.
SLIMM_SOAK_HOURS=12 flutter test --enable-vmservice test/soak/long_session_soak_test.dart
```

The report prints at the end and is written to `build/soak/soak-<label>.txt`, with every sample in `build/soak/soak-<label>.json`.

| Variable | Default | What it does |
| --- | --- | --- |
| `SLIMM_SOAK_HOURS` | unset | Simulated hours. Unset is the smoke run: one ten-minute epoch, two accounts, 120 members. |
| `SLIMM_SOAK_ACCOUNTS` | 3 | Signed-in servers. |
| `SLIMM_SOAK_MEMBERS` | 500 | Members per server. |
| `SLIMM_SOAK_LABEL` | `latest` | Names the report files, so a before and an after can sit side by side. |
| `SLIMM_SOAK_REPORT_ONLY` | unset | `1` prints the report without failing on growth, for measuring a tree that is known to leak. |
| `SLIMM_SOAK_TRACE` | unset | Class names, comma separated. Each undisposed instance of them is counted by the app line that created it. |
| `SLIMM_SOAK_RETAINERS` | unset | Class names, comma separated. Prints what keeps a few instances of each alive. Needs `--enable-vmservice`. |

Without `--enable-vmservice` the run still works and the heap rows read zero.

To compare a change, run once on the base with `SLIMM_SOAK_LABEL=before SLIMM_SOAK_REPORT_ONLY=1` and once on the change with `SLIMM_SOAK_LABEL=after`, then read the two text files together.
Do not run it beside another `flutter test` in the same package.

## What happens in a run

One epoch is ten simulated minutes, the period of the client's retention sweep, in sixty steps of ten seconds (`soak_driver.dart`).

Every step, on every account whether it is on screen or not: messages across the channels, two more into one busy channel, a typing start, a presence change, and on a slower beat reactions, edits, deletes and people joining and leaving voice channels.
An account out of view gets a third of the messages.

The person at the desk switches channel every minute.
Once an epoch they join a call and hang up, open settings and close it, join another call and leave it running, and switch to the next account.
The call left running is ended from the other account a little later, which is the "in a call on another server" path.

A sample is taken about twelve times a run.
Before each one the app is put back on the first account's first channel, so every sample reads the same screen.

## Reading the report

The table has one column per sample.

| Gauge | What it counts |
| --- | --- |
| `timers.pending` | Timers created and neither fired nor cancelled. |
| `live.listeners` | Open subscriptions to the live-event stream, over all accounts. |
| `objects.undisposed` | Framework objects created and not disposed: notifiers, states, elements, render objects, layers, tickers, images, pictures. |
| `providers.live` | Live Riverpod provider instances, over all accounts. |
| `tree.elements` | Elements in the widget tree. |
| `images.*` | Flutter's decoded image cache. |
| `db.messages`, `db.fullest_channel` | Message rows in the local stores, and in the one channel with the most. |
| `extras.entries` | Entries in the in-memory reactions and attachments map. |
| `bench.idle_rebuilds` | Widget rebuilds per frame with nothing arriving, as the floor for the next two. |
| `bench.rebuilds_per_message` | Widget rebuilds to take one message into the open channel. |
| `bench.background_rebuilds` | The same for a message in an account that is not on screen. |
| `bench.idle_frames` | Frames asked for per frame drawn with nothing arriving, as the floor for the next one. |
| `bench.background_frames.*` | Frames the window is asked to draw for one message, typing start or presence change in an account that is not on screen. Nothing on screen changes, so each is drawn for nothing. |
| `bench.*_us`, `bench.channel_switch_ms` | Real time for the same work. Debug build, software rendering: compare runs, not against a release build. |
| `since_last.*` | Rebuilds and real time since the previous sample. |
| `heap.kb`, `rss.mb` | Dart heap after a forced collection, and the process's resident size. |

Under the table, each breakdown lists what gained between the first judged sample and the last: undisposed objects by class, providers by what they hold and where they were first read, timers and listeners by the line that opened them, rebuilds by widget, and heap classes by bytes.
A climbing gauge names its cause there.

A run fails when a gauge it judges grew.
The smoke run judges timers, listeners and background rebuilds, which are exact.
A run of hours also judges undisposed objects, providers, tree size, cached images and rebuilds per message, comparing the median of the first third of its samples with the last third, after a quarter of the run as warm-up.
Two gauges are judged against a bound instead, because they are allowed to climb to it: the fullest channel against the store's thousand rows per channel, and the extras map against the open channels' share of that.
`db.messages` as a whole is reported and not judged: a thousand rows for every channel is the design.

## What it does not cover

- A real call. `VoiceSession`, LiveKit and the audio path are not in it.
- The real socket. Reconnects, catch-up and the frame queue are replaced by `deliver`.
- Native memory. Textures, decoded video and the engine's own caches do not show in the Dart heap; `rss.mb` is the only hint.
- A hidden window. Flutter draws no frames then, and nothing here models that.
- Release-mode timing.

## Adding to it

A new thing the person does is a method on `SoakDriver` and a line in `step`.
A new number is an entry in the gauges map in `soak_probe.dart`, and a `Level` in `soak_report.dart` if it must hold.
The fake community must stay a fixed size however long the run is, or the harness reports its own growth: each channel keeps only its newest 120 messages for that reason.

## What the first runs found (2026-11)

Three accounts, 500 members each.

| Finding | Before | After |
| --- | --- | --- |
| An account that left the screen never disposed or refreshed a provider again | In one hour: 16513 member profiles held, live listeners from 93 to 159, providers from 1967 to 4619 | 3031 profiles after an hour; over twelve hours listeners stay at 74 and providers settle near 3950 |
| Pictures recorded for an avatar, stamp or glow bake were never disposed | About 1900 undisposed an hour | None |
| A route's transition made new curves every frame | About 900 undisposed an hour | None |
| Three providers keyed by message id were never disposed | 513 to 1790 over twelve hours | Level |
| A message in the open channel rebuilt the shell and the pane around it twice | About 6750 rebuilds a message | About 5480 |

The first is the one that mattered.
`docs/internals.md`, account scopes, has the mechanism.

Twelve simulated hours after the fixes held level on every judged gauge.
Timers stayed between 14 and 17, the fullest channel stayed under 1110 rows, and the image cache filled to its cap of 1000 by the fifth hour.
The Dart heap went from 377 MB to 400 MB over those twelve hours, in a debug build; about a quarter of that was the harness's own bookkeeping, since removed.

Measured and left as it is:

- A message in the open channel still rebuilds the rail twice, because the channel flips to unread and back as the read marker follows, and the channel screen rebuilds on its own row stream.
- The local store keeps up to a thousand rows for every channel, so `db.messages` climbs for as long as there are channels that have not reached that.
- The call dock, a toast and the desktop entrance each leave a curve undisposed. Each goes with its controller, so nothing is held.
- An account out of view asks for about one frame for each message and each presence change, and none for most typing starts, where the window at rest asks for none. That is what keeping its scope mounted costs (decision 0068, the 2026-11-19 amendment). The message figure is a little high here: the fake community has no answer for the notification settings, so each message refetches them.
