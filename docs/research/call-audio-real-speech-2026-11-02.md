<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# Call audio with real speech, end to end (2026-11-02)

Decision 0105 (modules hear a call as text) had only been tested against a fake listener.
This note records one run of the whole chain with real speech, on v123/integration at 913f7c3ae.

## Result in short

1. It works end to end.
   Real speech from LiveKit participants became speech-to-text segments in the transcript module, attributed to the right user ids, with the right words (mean word accuracy 0.96 to 0.97).
2. The consent rules held on every path tried: nobody was transcribed before everyone agreed, a joiner was excluded until they agreed, a decline or a lapse started nothing, and stop ended it for everyone.
3. Nothing was written to disk by the listener, and the server wrote no audio and no text outside the module's own store and the messages the module posted.
4. Latency after the speaker stops was 2.3 s at p50 and 2.4 s at p95 and max, with two or four speakers, against a target of 5 s.
5. One finding: four people speaking at once peaked the listener at 964 MiB, under a 1 GiB compose limit.
   The compose limit is now 1536M (see "Bug found").

## What was run

- LiveKit v1.13.11 in a container, with its webhook pointed at the server, so the server learned joins and leaves the way production does.
- The server built from this tree (release profile), with `SLIMM_LISTENER_URL` and a 32 character secret.
- The listener as the real image from `docker/listener.Dockerfile`, with the same flags as the compose service: read-only root, all capabilities dropped, no-new-privileges, a 64 MB `/tmp` tmpfs, 4 cpus, an empty named volume for `/models`.
- A tap between the server and the listener, a small websocket proxy that logs every `listener/1` frame with a wall clock time and forwards it unchanged.
  It is how the include sets and the segment arrival times below were read.
- The transcript module from slim-addons PR 78 (commit 34ebf0a), installed as a module package, with `call.audio`, `data.store`, `message.post` and `schedule` approved.
  The `@everyone` role was given its `start` permission, and five voice channels were armed for it.
- Four accounts (alice, bob, carol, dave), each a LiveKit Python SDK participant publishing a microphone track.
  Each sent 10 ms frames continuously, quiet room noise between sentences, as a real microphone does.
- Speech from piper (the `en_US-lessac-medium` voice the voice harness uses), four sentences of 2.6 to 3.3 s, resampled to 48 kHz.
- The Python SDK was used rather than browsers.
  The two-browser scenario is phase 2 in the decision, and a browser-free run reached the same server and listener code paths.

## The model download

The first start of the listener container downloaded `ggml-base.bin` once into the empty volume and checked it against the pinned sha256 (`60ed5bc3...fba2efe`).
It is 147,951,465 bytes (141 MiB; the docs say about 148 MB).
On this machine's connection the download and the model load together took under 10 s.
The container sat at 359 MiB resident with the model loaded and no session.
The image is 193 MB.

## Consent checks, with evidence

All frames are from the proxy log; ids are mapped to account names.

| Check | What happened |
| --- | --- |
| Nothing before a session | Alice and bob spoke in the call with no session. No `start` frame, no segments. |
| Not everyone has agreed | Alice asked (`status: asking`, alice included, bob pending). Bob spoke while pending. No `start` frame, no segments. |
| Unanimous start | Bob allowed. One `start` frame with include = alice, bob. Alice and bob then each produced a segment with their own id. |
| A joiner is excluded | Carol joined and did not answer. Her view showed her as pending. No `include` frame was sent. Carol and bob spoke together: one segment, bob's, none from carol. |
| A joiner who agrees is included | Carol allowed. An `include` frame with alice, bob, carol was sent, and carol's next sentence came back as a segment with her id. |
| A joiner who says Not now | Dave joined, spoke while unanswered (no segment, never in an include set), then chose Not now. The session stopped for everyone: a `stop` frame went to the listener and the call showed no session. |
| Decline | Bob said Not now to alice's ask. No `start`, no segments after both spoke, and an immediate second ask was refused with 429 and a 51 s retry. |
| Lapse | Alice asked and nobody answered. After 63 s there was no session, no `start` frame, and no segments although bob spoke. A new ask was then refused with 429, so the retry wait applies after a lapse too. |
| Leave | Carol left a running session. An `include` frame with alice and bob followed within 4 s (the longest wait the run allowed). |
| Stop by anyone | Bob pressed Stop. A `stop` frame reached the listener, alice's view showed no session, and speech afterwards produced no segments. |
| Last person leaves | Alice left, bob stayed (session stayed on with bob alone), bob left, and a `stop` frame went out. |
| Hidden and listen-only | While a session ran, LiveKit's own participant list showed `listener-<session id>` with `hidden: true`. Alice's SDK did not list it among remote participants, and the call roster listed only the four people. |
| Server dies | Killing the server process while a session ran removed the listener from the room in under 0.5 s (the proxy closes the listener's side at once, so this is the fast case). |

Not exercised: the 25 person cap, the 4 hour limit, a hidden-presence member, a bot in the call, and the client prompt UI itself.

## What the listener and the server left behind

- `docker diff` on the listener container was empty (read-only root).
  `/tmp` was empty.
  The `/models` volume held `ggml-base.bin` and nothing else, no `.part`, no audio.
- The listener's logs contained none of the spoken words.
  The server log contained none of them.
- Every table of the core database was searched for the spoken sentences.
  They appear only in `messages` (the transcript the module posted) and its search index.
  The core database has no call-audio session or segment table, only `module_call_audio_channels`.
- The segment text also sits in the module's own database file, `modules/transcript.db` (80 segment rows after the run), which is what the module's `keeps` text tells people.
- No `.wav`, `.pcm`, `.opus` or `.raw` file appeared in the stack's work directory or on the machine outside the driver's own clips.

## Accuracy

Word accuracy is one minus the word error rate against the sentence piper was given.
Across 66 utterances in three runs it was 0.96 to 0.97, and every utterance produced exactly one segment.
The one recurring error was "upload" heard as "uphold".
Piper speech is clean, so this is an upper bound for real microphones.

## Latency and resources

Machine: Ryzen 9 9950X3D, the same as decision 0105's figures.
The listener ran in the container capped at 4 cpus and 1 GiB.
Latency is the time from the last voiced sample leaving the speaker to the segment frame reaching the proxy.
CPU is from the container's cgroup `cpu.stat`, in percent of one core, sampled each second.

| | 2 speakers (14 utterances) | 4 speakers (24 utterances) | 4 speakers (28 utterances, 24 of them overlapped) |
| --- | --- | --- | --- |
| Latency, in turn, p50 / p95 | 2.29 s / 2.32 s | 2.30 s / 2.33 s | 2.34 s / 2.37 s |
| Latency, all speaking at once, p50 / p95 | 2.29 s / 2.34 s | 2.38 s / 2.42 s | 2.29 s / 2.35 s |
| Word accuracy | 0.96 | 0.97 | 0.96 |
| CPU in a session, nobody speaking | 2% | 2% | 2% |
| CPU while speaking, mean / peak | 32% / 201% | 45% / 389% | 59% / 399% |
| Memory in a session, nobody speaking | 375 MiB | 488 MiB | 480 MiB |
| Memory, highest during speech | 723 MiB | 963 MiB | 950 MiB |

The cgroup peak over the whole run was 964 MiB and did not grow across the three runs, so it is a plateau and not a leak.
About 600 ms of every latency figure is the endpointer waiting for silence.
Latency barely moves between two and four speakers, even when all four speak at once, because the four workers each take one utterance.
The decision's target (p95 under 5 s with four people in turn) is met with a factor of two to spare.

## Bug found

The compose service limited the listener to 1G, and the README told operators to plan for 1 GB.
Four speakers at once, which fills all four workers, peaked at 964 MiB: about 60 MiB below the limit.
A longer call, a longer utterance or a slightly different kernel accounting would be enough for the kernel to kill the listener in the middle of a call.
The figure in the decision (582 MB) was measured with speakers in turn, so only one or two workers were busy.

Fix: `docker-compose.yml` now limits the listener to 1536M, `deploy/README.md` says to plan for 1.5 GB and why, and `scripts/lib/test_listener_memory_limit.py` fails if the limit falls below 1200 MiB.
Lowering `LISTENER_THREADS` is the other way to stay under 1 GiB, at the cost of latency under load, and was not measured here.

## Not done

- The scenario is not in the e2e harness.
  It needs the listener image, a 141 MiB model and a speech clip generator, and the harness's existing scenarios assume none of them.
  The driver used here stays outside the repository.
- The real-LiveKit listener test (`LISTENER_REAL_LIVEKIT`) was not run against this stack.
- The client UI (the prompt, banner and Stop control) was not driven; only the routes it calls.
