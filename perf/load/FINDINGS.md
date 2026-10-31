# Load test findings

First measurements from the k6 scenarios in this folder, taken 2026-10-17.
Read the method and caveats before trusting an absolute number; the ratios are more reliable than the values.

## Method

- Machine: Ryzen 9950X3D, Fedora 44, shared with other work while measuring.
  SMT siblings are CPU n and n+16.
- Server: glibc release build of commit `7a51848a4` (server 0.93.1), pinned to CPUs 0-7 unless a table says otherwise, fresh database per run.
  The musl rows use the binary from `ghcr.io/slim-m-org/slim-m-server:latest` (`sha256:5e31ae93…`), which is stripped and cannot be profiled.
- k6: `grafana/k6` v2.3.0 by digest, `--network host`.
  "Clean" runs pin k6 to CPUs 8-15 and 24-31, which share no physical core with the server.
  Earlier runs overlapped SMT siblings, which inflates the server's numbers somewhat.
- Profiles: samply, user-space frames only (this box has `perf_event_paranoid` at 2).
- Every row is a single run unless noted.
  Treat a knee as a range, not a point.

## fanout

1000 WebSocket listeners in one channel (the hub caps open sockets at 1024) with senders posting at a set rate.

| Offered deliveries/s | p95 send to delivery | Server CPU avg (peak) | Outcome |
| --- | --- | --- | --- |
| 176k, clean | 199 ms | 1.9 (4.6) cores | all delivered |
| 252k, clean | 448 ms | 2.9 (6.3) cores | all delivered |
| 300k | 1.5 s | peak 6.0 cores | every listener dropped with a resync, 34% delivered |

The knee is between 252k and 300k deliveries per second, and it is a cliff rather than a slope: once one subscriber lags past the broadcast capacity they all do, and each falls back to a full resync.
It reproduced in four runs, including the overlapped ones.
For comparison, the Python harness this replaces saturated itself near 100 listeners, so this is the first time the server's own limit has been seen.

### Where the time goes

At 176k deliveries per second, 67% of server samples are a single `memset`, called only from `SplitStream<axum::ws::WebSocket>::poll_next` inside `ws::serve`.
Reading the source, tungstenite 0.29 zero-fills its input buffer on every read attempt, 128 KiB by default, and `http/ws.rs` never sets `read_buffer_size`, even though inbound frames are capped at 4 KiB.
That reading is from source, not confirmed in a debugger.

A throwaway build with `.read_buffer_size(4096)` on the upgrade (reverted, not in this branch):

| Offered deliveries/s | Server CPU avg | p95 |
| --- | --- | --- |
| 176k | 0.54 cores (was 1.9) | 114 ms |
| 300k | 0.90 cores | 175 ms |
| 400k | 1.19 cores | 212 ms |
| 500k | 1.50 cores | 235 ms |

No drops at any of those rates.
At 500k, k6 itself was using about 12 of its 16 threads, so the server's real ceiling with this change is above what this rig can generate.
That A/B build also carried the SQLite flag below, so the two effects still need measuring apart.

## http_mix

2500 accounts doing 50% history pages, 15% channel list, 20% sends and 15% reactions, at a ramping arrival rate.

On 8 CPUs with clean pinning, p95 is 10 ms at 2500 requests per second, 138 ms at 3000, and about 2.1 s at 3500.
The knee is about 3000 requests per second.
Past it, throughput falls behind the target and latency queues steeply, with no 5xx responses or failed requests.
History pages are the slowest operation (p50 about 1.1 s at 4000, against 0.25 s for the channel list).

Adding cores past 8 makes it worse:

| Server CPUs | Last good step (req/s) | First broken step |
| --- | --- | --- |
| 2 | 2000 | 2500 |
| 4 | 2500 | 3000 |
| 8 | 3000 | 3500 |
| 16 | 1500 | 2000 |
| 8, musl image binary | 2500 | 3000 |
| 16, musl image binary | below 1500 | 1500 |

These used overlapped pinning, one run each except 16 CPUs, which was repeated.

### Where the time goes

At a sustained 4000 requests per second, 52% of samples are in sqlx worker threads.
About 15% of all samples are mutex primitives on 8 CPUs, rising to about 26% on 16.
Every caller of those mutexes in the 16-CPU profile is a SQLite allocation (`sqlite3Malloc` under `sqlite3_value_dup`, `sqlite3_free`, the page cache): by default SQLite takes one process-wide mutex around its memory statistics on every allocation, so more threads contend harder.

A throwaway build with `LIBSQLITE3_FLAGS=-DSQLITE_DEFAULT_MEMSTATUS=0` moved the 16-CPU last good step from 1500 to 3000 and cut mutex time to about 4%.
On 8 CPUs the knee barely moved, though p95 at 3000 dropped from 138 ms to 16 ms.

Inclusive time on the request path: `message_enrich::with_reactions` 13.4%, DTO serialisation 5.8%, the history query 4.8%, and the permission checks together about 9%.
That the remaining limit on 8 CPUs is the 8-connection SQLite pool is a guess; pool wait time was not measured.

## connect_storm

Clients connecting and resyncing at once, three rounds, 8 CPUs, clean pinning.

| Clients | Time to usable p50 (p95) | /sync p50 | Failures |
| --- | --- | --- | --- |
| 200 | 177 ms (184) | 127 ms | 0 |
| 500 | 443 ms (486) | 336 ms | 0 |
| 1000 | 924-1047 ms (1081-1137) | 758 ms | 8-19 of 3000 |

The cost is almost all `/sync`, about 0.75 ms of server time per client, roughly 1300 syncs per second, with server CPU peaking near 4 cores.
The failures are 503 "too many connections" from the 1024-socket cap, confirmed in the server log: old sockets were still closing when the next round arrived.

## Suggested fixes

Not applied here, since this branch only adds the tooling.

1. Set `read_buffer_size` on the WebSocket upgrade close to `MAX_FRAME_BYTES`.
   This is the largest win measured.
2. Build SQLite with `-DSQLITE_DEFAULT_MEMSTATUS=0` (`LIBSQLITE3_FLAGS` in `docker/server.Dockerfile` and the binaries workflow).
3. Cut the query count per history page, starting with reaction enrichment.
4. Revisit the 1024-socket cap before relying on reconnect behaviour at that size.

## Writer gate on the SQLite pool

`Store::begin_write` now lets one caller at a time wait for SQLite's write lock (a one-permit semaphore, 10 s timeout), and the pool has an explicit 10 s acquire timeout instead of sqlx's 30 s.
Before it, up to eight queued `BEGIN IMMEDIATE` writers could hold every pool connection while they waited, so a read had to queue behind them.
`tests/write_pool.rs` holds the write lock, queues twelve registrations, and asserts a read still answers within a second; it fails with the gate removed.

`http_mix`, STAGES=200,400,800,1200, 15 s each, USERS=300, three interleaved runs of the old and new binary on a shared 32-thread box (other agents building):

| Step | Old p95 (ms) | New p95 (ms) |
| --- | --- | --- |
| 200 | 1.6, 2.0, 18.1 | 1.2, 1.3, 1.8 |
| 400 | 19.8, 19.9, 22.7 | 17.6, 10.1, 19.5 |
| 800 | 5.8, 11.1, 19.9 | 11.6, 13.9, 16.4 |
| 1200 | 2.4, 1.8, 20.9 | 8.6, 6.4, 9.6 |

Send p95 was 21.2, 21.0 and 33.7 ms old against 21.5, 20.7 and 23.1 ms new, with no dropped iterations in five of six runs.
So this mix does not saturate the pool on this box and the change is neutral here; the starvation case is covered by the test, not by this scenario.

A first attempt that gave `begin_write` its own single-connection pool was much worse (send p95 5 to 6 s, thousands of dropped iterations).
Transactions on that connection hand it from one to the next with no gap, so the plain writers that poll SQLite's busy handler (reactions, most single statements) never got the lock.
Do not split writers onto a separate pool unless every write goes through it.

## Not done yet

- Variance: three runs each of `http_mix` on 8 and 16 CPUs and `fanout` at 252k and 300k, all with clean pinning.
- `fanout` and `connect_storm` on the musl image binary, and `http_mix` on musl with clean pinning.
- The `read_buffer_size` and SQLite-flag effects measured separately, then together.
- One run of `.github/workflows/load.yml` from the Actions tab.
- `load-run.sh` with stock samply on a machine that allows kernel sampling.
  Here, a samply built with kernel sampling removed stood in.
