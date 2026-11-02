# Screen share start-bitrate hint, measured (S8)

Audit item S8 in `voice-stream-audit-2026-11-02.md` asked to measure the screen share `x-google-start-bitrate` hint before changing it.
This note records what a local two-client run showed.
It is a web-client measurement only, so read the caveats before acting on it.

## What was compared

Three livekit_client builds, each a separate web bundle, same slim-m tree otherwise.

- A: upstream 2.13.1 (`ffc0a879383c4a347542fbfefe122c74006d7b91`, the release commit, fetched through the fork URL). Shares are uncapped: the hint is 0.9 x the layer sum.
- B: fork `slimm/v2.13.1-share-start-bitrate` at `10dd4a7d3ed4dc35acb668114eb926477765550d`. Shares get the camera cap, 1 Mbps.
- C: fork `slimm/v2.13.1-share-start-bitrate-3mbps` at `6a56580882c59bc7cda1df5cf9b902bfd486c89b`. Shares are capped at min(0.9 x layer sum, 3000 kbps), cameras keep 1 Mbps, no setup-time ramp for shares.

The hint that reached the offer SDP was read from `setLocalDescription` in the sender page, on every run.
It was 9000 for A, 1000 for B and 3000 for C, so each variant really ran what it claims.

## Setup

- The Python e2e harness (`scripts/e2e.sh`) with a throwaway scenario, not committed. Two headless Chrome 156 clients, real server, real LiveKit v1.10.1 in Docker on this box.
- Share tier 1080p60 (the client asked `getDisplayMedia` for 1920x1080 at 60 fps), fake screen of 1920x1080 with heavy motion: a canvas where 15 percent of 24 px cells change color every frame plus a moving disc. The harness's older text-scroll fake screen needs so little bitrate that it was only used for a pilot.
- Sender stats and viewer stats sampled once a second inside the pages, from the moment the share button was clicked, for 80 s.
- Conditions: unconstrained, and 8 Mbit/s ingress policing at the LiveKit container (`tc` ingress qdisc with a u32 `police rate 8mbit burst 200k drop` filter, run from the harness's netem sidecar). The filter counted every packet of the run (about 22 MB per run), so it was in the path.
- Two runs per cell, each a fresh join so each has a fresh peer connection and a fresh estimator. Raw samples are in the run output, not in the repo.

## Result in one paragraph

The hint did not change anything that could be measured.
All three variants, in both conditions, started the estimator at about 0.3 Mbps, ramped at the same slow pace, and were still climbing at 80 s.
The sender never got near 8 Mbps, so the policer never dropped a packet (0 drops in all 12 runs) and there was no loss, no RTT growth and no freeze difference to find.
A hint of 9000 kbps in the SDP did not make the estimator start any higher than a hint of 1000 kbps.

## Table: unconstrained (two runs per row, run 1 / run 2)

Time to steady is "not reached" because the sent rate was still rising at 80 s.
The time to first reach 1 Mbps and 2 Mbps sent (3 s average) is given instead.

| Variant | Hint in SDP (kbps) | Time to 1 Mbps / 2 Mbps sent | Sent Mbps at 20-30 s | Sent Mbps at 60-80 s | Lost packets, first 10 s | Lost packets, 80 s | RTT peak, first 10 s | Viewer frame at 3 s | Viewer frame at 10 s | Viewer reaches 1080p | Viewer freezes, first 10 s / 80 s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| A | 9000 | 17 s, 26 s / 17 s, 26 s | 1.65 / 1.77 | 2.77 / 2.37 | 0 / 0 | 0 / 0 | 1.3 / 2.0 ms | 960x540 @1 / @2 | 960x540 @3 / @1 | 31 s / 31 s | 0 / 0, 4 / 3 |
| B | 1000 | 17 s, 26 s / 17 s, 26 s | 1.77 / 1.79 | 2.30 / 2.45 | 0 / 0 | 0 / 0 | 1.0 / 1.0 ms | 960x540 @2 / @2 | 960x540 @1 / @2 | 32 s / 30 s | 1, 1 / 0, 1 |
| C | 3000 | 17 s, 26 s / 17 s, 26 s | 1.72 / 1.78 | 2.41 / 2.43 | 0 / 0 | 0 / 0 | 1.0 / 1.0 ms | 960x540 @2 / @2 | 960x540 @0 / @0 | 32 s / 31 s | 1, 3 / 0, 1 |

Estimator target bitrate (sum of the outbound layers) at 10 s was 0.50 to 0.53 Mbps in every run, and 0.9 to 1.2 Mbps at 20-30 s.

## Table: 8 Mbit/s ingress at the SFU

| Variant | Hint in SDP (kbps) | Time to 1 Mbps / 2 Mbps sent | Sent Mbps at 20-30 s | Sent Mbps at 60-80 s | Lost packets, first 10 s | Lost packets, 80 s | RTT peak, first 10 s | Viewer frame at 3 s | Viewer frame at 10 s | Viewer reaches 1080p | Viewer freezes, first 10 s / 80 s |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| A | 9000 | 16 s, 26 s / 17 s, 26 s | 1.77 / 1.66 | 2.50 / 2.32 | 0 / 0 | 0 / 0 | 1.0 / 1.0 ms | 960x540 @2 / @2 | 960x540 @2 / @3 | 31 s / 31 s | 0 / 0, 0 / 1 |
| B | 1000 | 17 s, 26 s / 17 s, 26 s | 1.76 / 1.78 | 2.45 / 2.50 | 0 / 0 | 0 / 0 | 1.0 / 1.0 ms | 960x540 @2 / @2 | 960x540 @0 / @2 | 32 s / 32 s | 0 / 0, 0 / 1 |
| C | 3000 | 17 s, 26 s / 17 s, 26 s | 1.72 / 1.74 | 2.51 / 2.41 | 0 / 0 | 0 / 0 | 1.0 / 1.0 ms | 960x540 @1 / @2 | 960x540 @2 / @2 | 30 s / 32 s | 0 / 0, 3 / 1 |

Policer counters after each 8 Mbit/s run: about 26,000 packets matched, 0 dropped.
Sent share video was under 3 Mbps for the whole 80 s, so the cap was never the constraint.

## Why it looks like this

The offer carries the hint, and the sender still starts at roughly 0.3 Mbps.
The share is published after the call is joined, so the peer connection already has an audio-only estimator running by then.
The most likely reading is that Chrome does not re-seed an established estimator from a start-bitrate value in a later offer.
This note did not prove that mechanism, only the outcome: 9000, 3000 and 1000 behave the same.
The estimator's own ramp (about 5 to 8 percent per second here, no fast probe) is what sets how long a share takes to reach full quality, about 30 s to a 1080p layer at the viewer.

## Recommendation: A

Keep upstream behavior and drop the fork pin.
The caps change nothing measurable on the web client, so they cost a maintained fork for no benefit seen.
The overshoot the audit worried about did not appear: no loss, no RTT growth and no freezes attributable to the uncapped 9 Mbps hint, even with a policer at 8 Mbit/s.

Commit to pin if the fork is kept anyway for other reasons: B, `10dd4a7d3ed4dc35acb668114eb926477765550d`, which this tree currently pins.
Upstream 2.13.1 is `ffc0a879383c4a347542fbfefe122c74006d7b91`.
C is not recommended: it adds a second cap to maintain and measured the same as B.

## Caveats

- Web client only. Linux, Windows and iPhone use native libwebrtc through flutter_webrtc, where the offer path and estimator may behave differently. Not measured.
- Only the share-after-join path was tested, which is how slim-m shares start. A share that is the first video on a fresh peer connection (a camera already on, or a reconnect that republishes) could honor the hint. Not tested.
- The 8 Mbit/s limit was never reached, so the overshoot case itself is untested, not disproved. To test it, the estimator would have to be driven above the policed rate, for example with a 2 Mbit/s policer, which was not run.
- Loopback through Docker has about 1 ms RTT and no cross traffic, so RTT and loss say little about a real WAN uplink.
- The first 30 s of every cell is dominated by the estimator ramp, so "steady" was not reached; 60-80 s values are given and were still creeping up.
- The viewer's frame rate at low target bitrate is low (0 to 3 fps in the first 10 s) because the encoder drops frames at a 0.3 to 0.5 Mbps budget on heavy-motion content. Viewer size is the layer the SFU picked for a 1920x1080 viewer window.
- A used the fork URL at the upstream release commit rather than the upstream repository, so it is byte-identical to upstream 2.13.1 but resolved from the fork.
- Two runs per cell; the runs agree closely, but this is not a statistical sample.

## Decision (2026-11-02)

The fork override is not shipped: the hint is never consulted on the path slim-m uses (a share published after join), and lowering it would only act in the one path that was not measured.
The fork Slim-m-org/client-sdk-flutter keeps the two branches for the day a change in livekit_client is needed; nothing pins it.
The finding that matters is the ramp itself, about 30 s to 1080p on an unconstrained link, which has its own card (Ready, "A screen share takes about 30 s to reach 1080p").
