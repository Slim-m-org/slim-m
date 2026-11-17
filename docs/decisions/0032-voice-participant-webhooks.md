# 0032 - Voice participant events come from LiveKit webhooks, not client self-report

Status: accepted
Date: 2026-09-24

## The gap

`http/ws/frames.rs` sent one voice frame, `VoiceActivityChanged { channel_id }`: a bare "something changed, go re-fetch the roster" nudge with no participant identity.
It fires from three places in `http/voice.rs` and `sweeps.rs`, each keyed off the client's own heartbeat (`POST .../voice/heartbeat`, a plain 15-second interval) rather than anything LiveKit itself reports.

Screen sharing had no signal at all, anywhere.
`voice/roster.rs`'s `ListParticipants` call only ever read `identity` and `name` off each participant, so even a client willing to poll harder could not learn who was sharing.

This blocked every voice-aware bot idea in the backlog: an announcer that says who is sharing, a looking-for-group trigger on "someone joined voice", a watch-party companion that finds the active call. All of them need a push signal naming a person, not a nudge to re-poll, and something has to actually know about screen shares.

## The choice

Two ways to learn "who joined, who left, who is sharing":

**(a) LiveKit webhooks.** LiveKit's room server already knows every one of these transitions authoritatively - it is the SFU, so `participant_joined`, `participant_left`, `track_published` and `track_unpublished` are things it observes directly, not things a client has to remember to report. Configuring `webhook: { api_key, urls }` in `livekit.yaml` makes it POST a signed `WebhookEvent` to us on each one.

**(b) Extend the client's own heartbeat.** The client already tells us it is on a call every 15 seconds; it could additionally report "I am sharing my screen right now" in that same call, using its own local LiveKit room state.

(b) needs no new deploy-time configuration and reuses code that already exists. It is also strictly less trustworthy: it is exactly the shape of self-report this project's own heartbeat doc comment argues against for liveness ("a terminated app runs no code" - the same is true of a crashed screen-share encoder, a killed capture pipe, or a client that simply has a bug in its own local state), it cannot tell us about a screen share started and stopped inside one 15-second window, and it duplicates state LiveKit already has correct by construction.

**Decision: (a).** LiveKit is the one process actually watching the room, so it is the one source that cannot drift from what the room really contains. The owner's own standing instruction is to weigh robustness and correctness over the deploy-time cost, and the cost here is genuinely small: no new secret (the webhook is signed with the same API key and secret voice already requires), and one line of `livekit.yaml` that `docker-compose.voice.yml` can set automatically for anyone using the shipped overlay.

`VoiceActivityChanged` is kept, unchanged, as the compatibility nudge for anything still polling the roster. It costs nothing to leave in place and a client that has not adopted the new frames still works exactly as before.

## What ships

Three new durable, channel-scoped `hub::Event` variants, each carrying `channel_id` and `user_id`:

- `VoiceParticipantJoined`
- `VoiceParticipantLeft`
- `VoiceScreenShareChanged { is_sharing_screen }`

Unlike `VoiceActivityChanged`, these name the participant. That is a deliberate departure documented on `VoiceActivityChanged`'s own doc comment ("naming a participant here would be a second, unfiltered way to learn who is on a call") - the departure is safe only because these three are gated on `VIEW_CHANNEL` like every voice frame, *and* on the named user's own chosen `Visibility` (`store.presence_visibility`), the same check `GET .../voice/roster` already applies. This is deliberately not the stricter live-connection check `TypingStarted`/`CanvasCursorMoved` use (`presence_status`, which requires the target's app websocket to be connected this instant): a voice participant's presence comes from the LiveKit room, not from this connection, so gating on the websocket would withhold a real join during an ordinary reconnect blip. `Visibility::Hidden` is what withholds; anything else, including a momentarily-disconnected websocket, does not.

A new `POST /voice/webhook` route receives LiveKit's webhook. It authenticates by verifying the request's own `Authorization: <JWT>` header against the configured LiveKit API key and secret (HS256, the claim carries a base64 SHA-256 digest of the raw body - the same verification LiveKit's own server SDKs perform), not by any session. It is reachable, and does nothing, on a deployment with no SFU configured; `403` on the signature failing; `204` on success including for events this server does not act on, so LiveKit never sees a delivery it should retry for those.

The room's true state is idempotency-tracked in a new in-memory `voice::live_state`, the same shape as `voice::heartbeat`'s `CallHeartbeats`: a lock-held check-and-set so a webhook retry (LiveKit retries on any non-2xx, and does not promise exactly-once even on success) cannot double-publish a join, and so a `track_unpublished` for a participant's second screen-share track (video and audio publish as two separate tracks) does not fire "stopped sharing" while the other one is still live.

`voice/roster.rs`'s `ListParticipants` call already returns each participant's published tracks (`ParticipantInfo.tracks: []TrackInfo`, each carrying a `source`); `is_sharing_screen` and `has_video` on `GET .../voice/roster` are read directly from that response, not from the webhook-fed tracker. This means the roster's own fields stay correct even on a deployment that has not configured the LiveKit webhook - only the real-time push events need it.

## Operator impact

`docker-compose.voice.yml` now sets LiveKit's `webhook.urls` to `http://server:8080/voice/webhook`, the server's own address on the compose network, keyed with the already-required `LIVEKIT_API_KEY`/`LIVEKIT_API_SECRET`. Anyone using the shipped overlay gets this for free on their next `docker compose up -d` once they pull the updated file - `deploy/README.md` says so explicitly, since LiveKit's config is only re-read on container start, not hot-reloaded.

A self-hoster running LiveKit anywhere other than the shipped overlay (a separate host, a different orchestrator) has to add the `webhook` block to their own `livekit.yaml` by hand, pointing at wherever their server is reachable from LiveKit; `deploy/README.md` documents the block to add.

Until that webhook is configured and reachable, nothing breaks: the roster keeps working exactly as it does today (`is_sharing_screen`/`has_video` are still correct, read straight from `ListParticipants`), `VoiceActivityChanged` keeps firing, and the three new events simply never fire. A bot built against `on_voice_join`/`on_voice_leave`/`on_screen_share` on such a deployment sees nothing, the same as if the feature were never called.

## Track source matching

LiveKit's proto names the screen-share track sources `SCREEN_SHARE` and `SCREEN_SHARE_AUDIO`. Documentation for the exact JSON string LiveKit's Go server emits for these disagreed across sources consulted while building this (some rendered them without the `SHARE` segment), so the matching in `voice/webhook.rs` and `voice/roster.rs` checks for the substring `SCREEN` in the reported source rather than an exact literal. Confirmed against the real pinned server (`livekit/livekit-server:v1.10.1`) with `scripts/e2e.sh`, webhook wired up: the literal is `SCREEN_SHARE`, matching the earlier code already relies on for the same string in `scripts/lib/e2e_voice.py`'s own `ListParticipants` assertions.

## A call learns of a silent participant from the webhook (2026-11-17)

LiveKit sends a participant who has never published a track to the rest of the call on a 3 s batch (`subscriberUpdateInterval` in `pkg/rtc/room.go`), while a publisher's updates go out at once.
So someone who joined muted appeared on the call stage 1 to 3 s after the server already knew, and their leave lagged the same way; measured with the `voice: someone joining shows` e2e scenario.
On a `participant_joined` that has published nothing, the server clears an attribute nobody sets (`announce`), which LiveKit always sends at once and which flushes the batched join with it.
A leave cannot be pushed that way, since the participant is gone, so a client in the call hides someone the moment `VoiceParticipantLeft` names them, for at most 5 s or until the room drops them itself.
The e2e stack now wires LiveKit's webhook to the server through a relay on the docker bridge, so e2e runs the way prod does.
