# Load tests and server profiling

k6 scenarios that push a disposable local slimm-server well past what `scripts/loadtest.py` can, and a runner that records a CPU profile of the server while they run.
`FINDINGS.md` in this directory holds the numbers measured so far.

## The one rule: local only

Everything here refuses to run against anything but a loopback address.
`scripts/load-run.sh` boots its own server on `127.0.0.1` and never accepts a target from the command line.
`scripts/lib/load_target.py` is the check, built on `scripts/lib/seed_guard.py` (`PRODUCTION_DOMAIN`, `PRODUCTION_HOSTS`), and it has no override flag.
Every Python helper and `lib/api.js` repeat the check, so a scenario run by hand with `BASE_URL` set to the live host throws before it sends a request.
The server binds `0.0.0.0` whatever the port, so a run is briefly reachable from the LAN; do not run it on a network you do not trust.

## What you need

- Docker, for k6.
  It runs from `grafana/k6` pinned by digest (v2.3.0) with `--network host`; nothing is installed.
- A Rust toolchain, for the release build.
- Python 3 (stdlib only) and curl.
- For `--profile`, `samply` (`cargo install --locked samply`).
  See "Profiling" for the `perf_event_paranoid` catch.

## Running a scenario

```bash
scripts/load-run.sh fanout -e LISTENERS=500 -e SENDERS=10 -e RATE=4 -e DURATION=30
scripts/load-run.sh http_mix -e STAGES=500,1000,2000,4000 -e USERS=2500 -e MAX_VUS=3000
scripts/load-run.sh connect_storm -e CLIENTS=500 -e ROUNDS=3 -e HOLD=10
```

The runner builds `slimm-server` in release mode (`SQLX_OFFLINE=true`, `CARGO_BUILD_JOBS=4` unless set), starts it on port 8195 (`LOAD_PORT` to change; the e2e stack uses 8095) with a fresh data directory, claims the deployment as an owner account, runs the scenario, and stops the server by PID.
Anything after the scenario name goes to `k6 run`, so sizes are `-e KEY=VALUE` flags.

Flags before the scenario name:

- `--no-build` reuses the binary that is already built.
- `--profile` records a CPU profile (below).
- `--musl IMAGE` runs the binary copied out of a server image instead of a local build.
- `--binary PATH` runs a binary you built yourself, for A/B comparisons.

Environment: `LOAD_SERVER_CPUS` and `LOAD_K6_CPUS` (for example `0-7` and `8-23`) pin the server and the k6 container to separate cores, which is the only way to keep one side from stealing the other's CPU on a shared machine.

### fanout

N listeners hold WebSockets, M senders post into one channel at a set rate, and every listener times each message from just before the send request to the frame arriving.

| Variable | Default | Meaning |
| --- | --- | --- |
| `LISTENERS` | 100 | sockets held open (the server refuses more than 1024 connections in total) |
| `SENDERS` | 5 | sending accounts |
| `RATE` | 2 | messages per second per sender (a user's write bucket allows a sustained 5) |
| `DURATION` | 30 | seconds of sending |
| `USERS` | listeners / 5 | accounts the sockets are spread over |
| `CONNECT_GAP_MS` | 20 | stagger between listeners connecting |

Offered load is `SENDERS * RATE` messages per second, each delivered `LISTENERS` times.
Thresholds: delivery p95 under 500 ms and p99 under 1 s, no failed sends, no listener that failed to connect, closed early, or was told to resync.

### http_mix

A ramping arrival rate of REST requests: message history pages (50%), channel list (15%), sends (20%), reactions (15%).
Each rate in `STAGES` is held for `STEP_SECONDS` after a two second ramp, and the summary prints one line per step with the achieved rate and p50, p95 and p99.
The knee is the first step whose p95 breaks the budget or whose achieved rate falls short of the target.

| Variable | Default | Meaning |
| --- | --- | --- |
| `STAGES` | 50,100,200,400,800,1200 | target requests per second, one step each |
| `STEP_SECONDS` | 20 | seconds held per step |
| `USERS` | 300 | accounts; reads are limited to 8 per second per account, so use at least rate / 6 |
| `CHANNELS`, `HISTORY` | 3, 200 | channels, and seeded messages in each |
| `MAX_VUS` | 1000 | k6 virtual users available; raise it above the rate times the latency you expect |
| `P95_BUDGET_MS` | 300 | the per-step budget |

A request answered with 429 counts in `rate_limited`, not in the latency numbers, because it says nothing about the server.
`dropped_iterations` means k6 had no free virtual user for an arrival, which is what a saturated server looks like from the client.

### connect_storm

Every client connects (ticket, WebSocket hello, then `/sync` with cursors a few messages behind), holds the socket, and at a shared wall-clock barrier all of them drop and reconnect at once.
That is the reconnect herd the comments in `crates/slimm-server/src/http/ws/authorization.rs` worry about, without a server restart.
`time_to_usable_ms` runs from the barrier to the end of the sync.

| Variable | Default | Meaning |
| --- | --- | --- |
| `CLIENTS` | 200 | simultaneous clients |
| `ROUNDS` | 3 | connect rounds; the first is the initial connect, the rest are herds |
| `HOLD` | 10 | seconds between barriers |
| `JITTER_MS` | 0 | random delay added after each barrier, to see what backoff would buy |
| `LAG` | 20 | how far behind each channel cursor starts |

### routes

The routes the admin analytics page lists as slowest, driven the way a channel drives them: a burst of first-time `?w=320` previews of large JPEGs, then repeat downloads with and without `?w=` and the voice roster at a steady rate.
It uploads its photos itself, from a directory of fixtures mounted at `/fixtures`.

```bash
python3 perf/load/make_photo.py /tmp/fixtures/photo-6000x4000.jpg 6000 4000 97
LOAD_FIXTURES=/tmp/fixtures LOAD_FAKE_LIVEKIT=1 scripts/load-run.sh --profile routes -e PHOTO=photo-6000x4000.jpg
```

`LOAD_FAKE_LIVEKIT=1` starts `scripts/lib/load_fake_livekit.py` on the next port up and points the server at it, so the roster has an SFU to ask; `LOAD_FAKE_LIVEKIT_DELAY_MS` (default 40) is how long it takes to answer, and the run's `fake-livekit-calls.txt` counts what reached it.
Link previews are not driven here, because the SSRF guard refuses the loopback page a local run would serve; `tests/link_preview_image.rs` and `tests/link_preview_cache.rs` count them at a fake upstream instead.

| Variable | Default | Meaning |
| --- | --- | --- |
| `PHOTO` | `photo-6000x4000.jpg` | file in `LOAD_FIXTURES`; each upload gets a distinct hash from a trailing byte string |
| `COLD_PHOTOS` | 8 | photos, and virtual users asking for a first preview at once |
| `COLD_START` | 0 | seconds before that burst; 10 lets the upload-time previews finish first |
| `ORIGINAL_RATE`, `PREVIEW_RATE` | 4, 40 | repeat requests per second without and with `?w=` |
| `ROSTER_RATE` | 100 | roster requests per second |
| `WARM_SECONDS` | 20 | length of the repeat phase |

## Reading the results

Each run writes `perf/load/results/<timestamp>-<scenario>/`, which is gitignored:

- `summary.txt` and `summary.json`: the k6 metrics, thresholds, and for `http_mix` the per-step table.
- `server-resources.txt` and `.csv`: the server's CPU (in cores) and RSS sampled once a second from `/proc`, plus the same for k6.
  If k6's CPU is near the cores it was given, the result is k6's ceiling, not the server's.
- `metrics-before.txt` and `metrics-after.txt`: the server's own `/metrics`, before and after.
- `k6.log`, `server.log`, `run.txt` (which binary, which commit, how many cores).
- With `--profile`: `profile.json.gz`, `profile.json.syms.json` and `profile-top.txt`, and `flamegraph.svg` when `inferno-flamegraph` is installed (`cargo install inferno`).

Two caveats for `fanout`.
`delivery_ms` includes the send's own round trip, and `Date.now()` has millisecond resolution, so sub-millisecond numbers are not meaningful.
The listener and the sender clocks are the same process's clock, so there is no skew to correct.

## Which build you are measuring

The default is the glibc release build with the repository's `[profile.release]` (size-optimised, LTO), run directly on the host.
Production runs the static musl build from `docker/server.Dockerfile`.
Earlier measurements (`scripts/loadtest.py`'s docstring, `docs/dependencies.md`) found the CPU per delivered message about three times higher on musl's allocator than on glibc, so treat a glibc number as optimistic and confirm with the real image:

```bash
scripts/load-run.sh --musl ghcr.io/slim-m-org/slim-m-server:latest http_mix -e STAGES=1000,2000,3000
```

That binary is stripped, so it cannot be profiled.

## Profiling

```bash
scripts/load-run.sh --profile http_mix -e STAGES=4000 -e STEP_SECONDS=40 -e USERS=2500 -e MAX_VUS=3000
```

A profile run builds the `profiling` profile (release plus line tables, not stripped) with environment overrides, into the same target directory as the release build, so the shipped profile is untouched.
The server runs under `samply record`, and the profile lands in `profile.json.gz`.
`profile-top.txt` lists the busiest threads and the top frames by self and inclusive time, counting only the samples after seeding finished.
For the interactive view run `samply load <results>/profile.json.gz`, which opens the Firefox Profiler.

Two things about samply on Linux:

- It needs `kernel.perf_event_paranoid` of 1 or lower, because it always asks for kernel samples.
  On a box at the common default of 2 it exits with a message saying so.
  Either `sudo sysctl kernel.perf_event_paranoid=1`, or build a samply with the `.sample_kernel()` calls removed from `src/linux/perf_group.rs` (user-space frames only, which is all the server's own code needs) and point `SAMPLY` at it.
- It opens one perf buffer per CPU per thread, which can exceed `perf_event_mlock_kb` on a wide machine and fail with "mmap failed".
  The runner pins a profiled server to the first 8 CPUs unless `LOAD_SERVER_CPUS` is set.

## Limits that shape a run

- The hub caps open WebSockets at 1024, so `fanout` scales by message rate, not by listeners, past that.
- Rate limits are per account, so scale `USERS` with the rate.
  The runner starts the server with `SLIMM_TRUST_PROXY_HOPS=1` so that seeding can use a distinct forwarded address per account instead of waiting out the per-address password bucket.
- Access tokens last fifteen minutes and the scenarios do not refresh them, so keep a run under that.
- k6 and the server share the machine.
  Pin them apart, and watch `k6-resources.csv`.

## CI

`.github/workflows/load.yml` runs one scenario by hand (workflow_dispatch) and uploads the results directory.
It is not a PR check, and a shared runner is far too small to compare against numbers taken on a workstation.
