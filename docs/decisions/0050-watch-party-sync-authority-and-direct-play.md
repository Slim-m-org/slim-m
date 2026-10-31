# 0050 - The watch party keeps its shared track and gains per-viewer direct play

Status: accepted (a design decision); stage 1 (#1527), stage 2 (slim-bots Quick Connect links), and stages 3 and 4 (the per-viewer player and the floor that lifts) are built, and stage 5 is not; the viewer signs in to Jellyfin on their own device and the bot stores no tokens (section 4, owner-confirmed 2026-10-31)
Date: 2026-09-30
Extends: 0035 (module or bot), 0045 (bot-contributed UI), 0014 (canvas video subscription culling)
Relates to: 0021 (module ABI), 0023 (mediated host capabilities), 0043 (scene timeline), 0010 (canvas media tiles)

## The ask

The owner, 2026-09-25: "would the jellyfin bot be better as a bot who interacts with the jellyfin client but then we have a video playback module for canvas's/voice calls?"

He asked it in the same breath as "bitrate of jellyfin bot streaming isnt the best", and the two are one question.

## What the pipeline actually does today

Read out of `slim-bots` at `63276ce`, not assumed.

`bots/jellyfin/stream_session.py`'s own first line names the whole chain: "Jellyfin server-side transcode -> ffmpeg decode -> LiveKit screen-share publish pipeline for `!watch`".

So a frame is encoded twice before anyone sees it.
Jellyfin transcodes the source to H.264/AAC in an mkv progressive stream, capped at `VideoBitrate` (`jellyfin_core.build_stream_url`).
ffmpeg on the bot host decodes that back to raw I420 and letterboxes it into an exact WxH through a fifo.
`slimbots.voice.publish_screen_share` then wraps the frames in `rtc.VideoSource` / `LocalVideoTrack` and LiveKit encodes them a third time for the wire, at `VideoEncoding(max_bitrate=...)`.
Everybody in the call watches that one track.

`quality.py`'s presets are 854x480 at 1.5 Mbps, 1280x720 at 4 Mbps and 1920x1080 at 8 Mbps, and its own `HEAVY_WARNING` carries the measured cost: the software encode goes from about 20% of a core to about 87% of a core between 720p and 1080p.

That is the problem stated properly.
The picture is a transcode of a transcode, the host pays a core to make it, and the deployment pays upstream bandwidth per viewer, to hand everyone a worse copy of a file that is sitting on a disk they may already be able to read.

## What the per-user account mapping gives, and what it does not

slim-bots #60 to #64 shipped per-member Jellyfin accounts, and the inversion depends on them, so this is exact rather than summarised.

It gives one table in the bot's own sqlite, `user_links(slimm_user_id, jellyfin_user_id, jellyfin_name, linked_at)`, and `accounts.user_for` resolves a member to a Jellyfin user id.
Everything downstream then passes `userId=` on a Jellyfin call made with the deployment-wide admin API key, so a member's resume position, continue-watching list and progress writes are their own (`playback_progress.report_position`, `fetch_last_watched`).
One Jellyfin account maps to at most one member.

It does not give a credential.
There is no per-member token anywhere in the bot.
The only secret is `JELLYFIN_API_KEY`, which `playback_progress`'s own docstring says outright can act as any user, and which must never leave the bot host.

It also does not give proof.
`accounts.run_link` takes a username, resolves it through the admin key's `GET /Users`, and writes the row.
There is no password check and no Jellyfin-side confirmation.
The `owner_of` check refuses a name already claimed by someone else, which is squatting protection, not verification: the first member to type a name gets it.

That is load-bearing, and it is the single fact that most shapes the design.
An unverified link cannot authorize handing out access to a Jellyfin account, because a member could claim a name that is not theirs and be handed reach into a library they were never given.
So the mapping as shipped is enough to personalise resume and progress, which is what it was built for, and not enough to be the basis of per-viewer streaming.

Jellyfin also has no per-item scopable credential, so the card's "the bot mints a short-lived per-viewer token per session" does not exist in its API.
An API key acts as any user with full rights; the only per-user credential Jellyfin issues is the access token from `POST /Users/AuthenticateByName`, which needs that user's password.

## A video playback module is not possible, and this is not a judgement call

The card and the owner's question both float a module.
A module cannot do this, on three independent counts, each read out of the record that decides it.

Decision 0021's Module ABI v1 is import-free by construction.
A module exports `alloc` and `run` and one memory, and imports nothing, and "the host refuses to instantiate a module that declares any wasm import at all".
"No imports means a module can only compute - it cannot touch the network, the filesystem, or anything else in the host process."

Decision 0023 opens named doors rather than lifting that, and the doors that exist are `kv.store` and `message.post`.
Network egress from a module stays default-deny, and each new capability is its own security review.
There is no fetch capability, and adding one is not a small step for the thing that would need it here: a module reaching an arbitrary external host is the exact shape decision 0019's SSRF posture exists to refuse.

Rendering is the scene contract, and the scene contract has no video.
`scene/1` is a logical canvas plus a bounded op list of `cells`, `rect`, `circle`, `line`, `text`, `path` and `input`, painted by one `CustomPainter`, and 0021 already names the ceiling in its own words: "a retained-scene model over a request/response round trip, not a framebuffer".
Decision 0043 adds a linear `sweep` tween and nothing more, and its clock is the client's, run once per frame received, so a module cannot even hold a timer of its own.

So "a video playback module" is ruled out.
What the owner is actually describing, and what decision 0035's own worked-cases table already calls it, is a split: the bot holds the credential and the clock, and the pixels are a first-class client surface, not a sandboxed guest.
0035 lists "Jellyfin watch party" as "Both", with the bot as "the sync authority" and the module as "the native video surface".
This record keeps the split and corrects the second half: the surface is core client code, because a module cannot fetch and cannot draw a frame.

## The reachability answer, plainly

For a viewer outside the LAN, direct play does not work, and no amount of client work changes that.

The bot reaches Jellyfin over `JELLYFIN_URL` from the bot host, which sits on the same LAN as Jellyfin.
The deployment forwards only 80 and 443 from the router, so nothing else is reachable from outside at all.
The public hostname is Cloudflare-proxied.

Cloudflare's own service-specific terms (read 2026-09-30, last updated 2026-09-28) settle whether a film may ride that hostname.
The Free, Pro and Business CDN "can be used to cache and serve web pages and websites", a non-Enterprise customer "must use" a paid service such as Stream "in order to serve video and other large files via the CDN", and Cloudflare "reserves the right to disable or limit your access to or use of the CDN ... if you use or are suspected of using the CDN without such Paid Services to serve video".

So the routes for an off-LAN viewer are a VPN or tailnet into the LAN, a DNS-only unproxied hostname on a forwarded port, or slim-m proxying the bytes.
The first is the honest one and needs no slim-m work, though who gets on the tailnet is the owner's call.
The second drops Cloudflare in front of a service holding the whole media library, which is a worse trade than the bandwidth it saves.
The third reintroduces exactly the per-viewer server bandwidth the inversion exists to remove, and puts slim-m in the business of relaying arbitrary upstream bytes.

**Decision: slim-m does not proxy Jellyfin.**
Direct play is offered where a viewer's own client can reach Jellyfin, and the shared track covers everyone else.
That is why this record recommends a reduced form and not a replacement.

## Decision

### 1. The shared track is the floor and direct play is a per-viewer upgrade

Both shapes ship, and both stay.
This is not a migration with an end state where the bot stops encoding.

The bot keeps publishing the screen-share track it publishes today.
A viewer whose client is eligible plays the same title from Jellyfin themselves, at source quality, and unsubscribes the bot's track.
A viewer who is not eligible sees exactly what they see now.

The floor is not a courtesy.
It is what a direct-play viewer falls back to when their own playback stalls, and it is the only shape that works for a member with no Jellyfin account, no reachability, or a browser that cannot play the file.

### 2. The encode stops only when nobody is on the floor

The host-cost win is real but conditional, and this is where it lands.

While at least one viewer in the call is on the shared track, the bot pays the full encode, and the only win for the direct-play viewers is picture quality.
Once every viewer in the call has resolved to direct play, the bot unpublishes and stops the ffmpeg pipeline, and it republishes the moment one viewer needs the floor again.
`slimbots.voice.unpublish_screen_share` already exists for exactly this kind of teardown, since `!quality` uses it to republish at another size.

Stating the condition matters more than the feature: in a mixed room the CPU saving is zero, and a design that claimed otherwise would be wrong.

### 3. Who can watch, and what the ineligible viewer sees

Eligibility is three independent tests, and a viewer is told which one they failed.

A viewer needs a **verified** Jellyfin link, a client that can reach `JELLYFIN_URL`, and a Jellyfin account whose library actually contains the item.

Nobody is silently excluded and nobody gets a black tile.
The watch surface carries one line naming the state and the action that changes it.

- No link: "watching the shared stream. link a jellyfin account to watch at source quality."
- An old unverified link: "watching the shared stream. your jellyfin link is not verified yet."
- Cannot reach Jellyfin: "watching the shared stream. this device cannot reach jellyfin directly."
- The account cannot see the item: "watching the shared stream. your jellyfin account cannot see this title."

Each of those is a working watch party, at today's quality, not a failure.

### 4. A verified link, and the viewer signs in on their own device

`!jellyfin link` has a verified path (stage 2, Quick Connect): the member proves they own the Jellyfin account, and the bot records the link as verified.
The bot keeps no Jellyfin token for anyone; stage 2 logs the Quick Connect token out once the link is verified.
An unverified link keeps working for resume and progress exactly as before, and is simply not eligible for direct play.
`!jellyfin account` says which kind a member holds.

For direct play the viewer's own client signs in to Jellyfin with their name and password, and keeps only the returned token in the device's key store.
The owner confirmed this on 2026-10-31, over the first draft of this section, which had the bot store each member's token and hand it back per session.
A bot holding a token for every member would make the bot host a store of everyone's Jellyfin credentials, so a bot compromise would reach every account; with the token on the viewer's device, the reach of any one leak is that one person.
The cost is one sign-in per device, which the panel asks for the first time a viewer turns direct play on.

The admin API key never leaves the bot host, and a `user_links` row alone never buys reach it did not already have.

### 5. State rides the durable record, the heartbeat rides a new ephemeral event

Two channels, because neither one does both jobs.

A **watch session** is durable state the bot owns and the client can read over REST: item, whether it is playing, the position and the wall clock that position was sampled at, an epoch that changes on every seek or title change, and who holds control.
A late joiner, a reconnect and a resync read it there, which is the project's own rule that a client that fell behind recovers over REST rather than from the stream.

A **tick** is a new ephemeral hub event, one every 5 seconds, carrying the same position and sample clock.
It belongs on the ephemeral channel for the reasons `hub.rs`'s `is_ephemeral` already gives for `CanvasCursorMoved`: it carries no `seq`, it is never persisted, a receiver ages it out on its own, and a missed frame is corrected by the next one rather than leaving anything stuck.
The rate is not close to a limit.
`Class::CanvasCursor` is sized at 30 burst and 15 per second sustained; a watch tick asks for 0.2 per second.

The panel message keeps doing what it does now and is not the sync channel.

### 6. Two seconds, and why not tighter

**Tolerance is 2 seconds between viewers.**

The bar people imagine is lip-sync, and that is the wrong bar, because no viewer ever hears anyone else's copy of the film.
Each client plays its own audio, so a spread between two viewers is never audible as an echo.
What the spread actually costs is reaction timing: somebody laughing or saying "wait, what" over voice should land while everyone is still in the same shot.
Ordinary shots run a few seconds, so a couple of seconds of spread keeps a reaction in the moment it belongs to, and tightening past that buys nothing anybody perceives while costing a correction everybody does.

The correction rule is graded, because a hard seek is far more disruptive than the drift it fixes.

- Under 0.25s: do nothing.
- 0.25s to 2s: change playback rate by up to 5% until the error closes, then return to 1.0.
- Over 2s, or any epoch change: seek.

A client that cannot hold the line gives up rather than stuttering.
Three corrections inside 60 seconds, or a stall over 10 seconds, drops that viewer back to the shared track with a line saying so and a way to try again.
That is the second reason the floor exists.

### 7. Control does not change, because it is already right

`watch_cog._may_control` is the person who started the party, or a member with `MANAGE_CHANNELS`, and that already governs `!pause`, `!resume`, `!seek`, `!subs` and `!quality`.
Decision 0045's call controls are visible to everyone on the call, and the bot applies the same check when one is pressed.
Keep all of it.

What stops one person yanking the position for everyone is that a viewer's own player holds no authority.
A local pause is local, and the surface says so: "you are paused, the room is at 01:23:45", with one action to rejoin the room's position.
Only a control-holder's action reaches the bot, and only the bot moves the room.

One gap to close with it: if the starter leaves the call, control passes to the longest-present member holding `MANAGE_CHANNELS`, and if there is none the session ends the way it already does when a call empties.

### 8. The surface is the call stage first, and the canvas tile later

The player is core client code, mounted where the bot's screen share renders today, so the two shapes swap in one place.

This is not a from-scratch build.
`media_kit` 1.2.6 with `media_kit_video` 2.0.1 is already a dependency of `packages/app`, chosen there precisely because it is the only cross-platform player that covers desktop Linux, and `attachment_video_source_io.dart` / `attachment_video_source_web.dart` already split the platform paths for attachment playback.

A canvas tile comes later, if it is wanted.
Canvas presence tiles are keyed `camera:<identity>` and `screen:<identity>`, carry per-viewer overrides with shared placement, and render a LiveKit track; a watch surface is a new tile kind rather than a presence tile, and the shell that drags, resizes, locks and hides one is reusable as it stands.
Building the call surface first does not close that door, because both mount the same player against the same session state.

One consequence to carry into the build: decision 0014 culls canvas video subscriptions to protect a bounded number of hardware decode sessions, and a `media_kit` player is a decode session that `setVideoInterest` knows nothing about.
A direct-play viewer does not subscribe the bot's track, so the two never stack on one client, and that is the invariant to hold rather than an accident to rely on.

### 9. What is lost, said plainly

The current shape's real virtue is that it asks nothing of anyone.
Join the call and you see the film, with no Jellyfin account, no link, no LAN, on any client including the web one.
Direct play trades that away for the viewers who take it, which is why it is an upgrade and not a replacement.

Subtitles and quality stop being one thing.
`!subs` burns subtitles into the shared encode and `!quality` resizes it, so both are properties of the floor.
A direct-play viewer picks their own, which is better, and it means a control-holder's `!quality` no longer changes what they see, and the room is no longer literally looking at the same pixels.

The transcode cost may move rather than disappear.
"No re-encode" holds only where a client plays the original file as it is.
`media_kit` on desktop and mobile usually can, and a browser usually cannot, so a web viewer will normally pull a Jellyfin transcode of their own, and N such viewers are N transcode sessions on the Jellyfin box at source resolution.
That is a cost the original framing does not mention, and the first measurement should be exactly this, per platform, before stage 4 is trusted.

## Recommendation

**Do it, in the reduced form above.**

The direction is right and the card is right that it fixes the bitrate at the root instead of tuning it.
What does not survive contact with the code is the full inversion: the mapping that shipped proves no identity, Jellyfin issues no per-item credential, the module system cannot hold a video element on three independent counts, and an off-LAN viewer has no lawful route to the bytes.
So the bot becomes the sync authority for everyone, and fetching the bytes yourself is a per-viewer upgrade that some viewers will never be eligible for.

Both shapes coexist permanently.
The rewrite the card warns against does not happen, and the current path is never removed.

## Stages

Each stage is worth shipping alone, and each one leaves the product better if the next never lands.

**Stage 1, the first shippable slice: the watch session and a real position readout.**
The bot publishes durable session state and the 5-second tick, and the client shows the room's actual position, a progress bar and the playing or paused state on the call surface.
Nothing about the video changes and today's track keeps playing.
This proves the whole sync protocol with no reachability and no credential risk, and it closes decision 0045's own open question, which left "position, and any state that changes as it plays" out on purpose.

**Stage 2: verified Jellyfin links.**
The password path, the per-member access token stored encrypted in the bot's store, and `!jellyfin account` reporting which kind of link a member holds.
Unverified links keep working for resume and progress.

**Stage 3: the direct-play surface, per viewer, off by default.**
The `media_kit` player mounted where the shared track renders, driven by stage 1's state, with the graded correction and the fallback.
Measured on the way out: Jellyfin CPU per direct-play viewer, whether the original plays untranscoded on each platform, and the observed spread between two real clients.

**Stage 4: the floor lifts.**
The bot unpublishes once every viewer in the call is direct-playing, and republishes when one is not.
This is the host-cost win, and it needs stages 1 to 3 measured first.

**Stage 5, optional: the same player as a canvas tile kind.**
Only if the owner wants a watch party on the canvas rather than in the call.

Explicitly not planned: a slim-m proxy for Jellyfin bytes, Jellyfin behind the Cloudflare-proxied hostname, and any module-shaped video surface.

## Open, for the owner

- Whether off-LAN guests get on a VPN or tailnet to the LAN, which is the only route that makes direct play work for them.
