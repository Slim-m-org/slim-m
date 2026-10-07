# slim-m server performance baselines

This directory is the Phase 0 performance measurement scaffolding for
`crates/slimm-server`.
It does not enforce a regression gate yet.
It exists so that every release leaves behind one comparable, versioned
record of how fast the hot paths were at that point in time.

## The one-JSON-baseline-per-release model

Each server release gets exactly one committed baseline file.
The file lives at `perf/baselines/<version>.json`, where `<version>` matches
the `slimm-server` release version (for example `perf/baselines/0.3.0.json`).
There is no rolling "latest" file and no per-commit history.
A baseline is a snapshot taken at a release boundary, not a continuous trace.

`perf/baseline.example.json` in this directory is not a real baseline.
It is a template showing the required shape, so a new baseline file can be
produced by copying it and filling in real numbers.

Each baseline file has:

- a top-level `version` field, the `slimm-server` release version the
  numbers were captured against
- a `metrics` array, one entry per benchmark, each with:
  - `name`, the criterion benchmark name (for example `uuid_now_v7`)
  - `value`, the measured point estimate
  - `unit`, the unit the value is expressed in (for example `ns`)

Four entries are not criterion benchmarks: `idle_rss_glibc`, `peak_rss_glibc`,
`idle_rss_musl` and `peak_rss_musl`, all in kB.
They exist because the Phase 1 exit criterion is stated in terms of resident
memory rather than throughput, and a number nobody records is a number nobody
can hold a release to.
The libc is part of the metric name, not a side note, because glibc and musl
genuinely measure different things here (musl's allocator fragments
differently under Tokio) and a bare `idle_rss` name has already caused one
baseline (0.8.0) to record a glibc number with no way to tell that from the
name alone.
See "Measuring idle RSS" below for how to take them.

Keeping the shape flat and per-metric means a new baseline can be diffed
against the previous one metric by metric, without needing to parse
criterion's own (much larger) internal JSON format.

## Running the benchmarks locally

```sh
cargo bench -p slimm-server
```

This runs both Phase 0 benchmarks in `crates/slimm-server/benches/hot_paths.rs`
and writes a full HTML report plus raw JSON estimates to `target/criterion/`.
Open `target/criterion/report/index.html` to browse it.

To check that the benchmarks still compile without spending the time to
actually run them, use:

```sh
cargo bench -p slimm-server --no-run
```

## How CI uses this

`.github/workflows/perf.yml` treats compiling and running the benchmarks as
two separate, differently-priced steps:

- On every pull request touching `crates/**` or `perf/**`, CI only compiles
  the benches (`cargo bench --no-run`).
  This catches a benchmark that no longer builds without paying for a full
  measurement run on every push.
- On a published GitHub release, CI runs the benchmarks for real and
  uploads the `target/criterion` output as a workflow artifact.

Turning that uploaded criterion output into a new committed
`perf/baselines/<version>.json` is a manual step for now: pull the relevant
point estimates out of the artifact and add them to a new baseline file in
the same pull request that finalizes the release.
Automating that extraction is a later phase, not part of this scaffolding.

## Measuring idle RSS

STRATEGY.md budgets the server at under 30MB resident at true zero load, and
the Phase 1 exit criterion is that the figure has actually been measured.
Take it against a release build, not a debug one, with nothing connected, on
both libcs: the host's glibc, and the musl build every release actually ships
(built the same way CI builds it, from the committed
`docker/server.Dockerfile`, so it needs Docker but not a musl toolchain
locally).

`perf/measure-idle-rss.sh` automates both, after you build the glibc binary:

```sh
cargo build --locked --release --bin slimm-server
perf/measure-idle-rss.sh
```

It starts each build with nothing connected, confirms it over `/healthz`,
reads `VmRSS` (the steady idle figure the budget refers to) and `VmHWM` (the
high-water mark, which peaks during startup migrations and never recurs, so
it is worth recording separately rather than mistaking it for the idle cost)
out of `/proc/<pid>/status`, then tears the process or container down.
Run it with `--skip-musl` if Docker is not available, or `--skip-glibc` /
`--skip-musl` to isolate one side while debugging the other; the full flag
list is in its own header comment.

Take several readings rather than trusting a single run.
RSS is noisy enough (page-cache timing, what else the host is doing) that one
sample can read 2-3% high or low; the 0.15.0 baseline below is the median of
five runs of the script, and each individual run printed within about 2% of
that median on this machine.

The 0.8.0 baseline was taken this way on Fedora with glibc only, measuring
7,296 kB idle and 25,760 kB peak, and flagged that releases ship musl instead
without being able to measure it.
0.15.0 is the first baseline with both figures: see
`perf/baselines/0.15.0.json` and the release notes for the comparison, and do
not compare a `_glibc` figure against a `_musl` one, or either against the
unqualified `idle_rss`/`peak_rss` names 0.8.0 used before this split existed.

**Every server release now measures itself in CI.**
`perf.yml`'s `baseline` job runs on each published `server-v*` release, on that release's own commit: the criterion benchmarks, then `perf/measure-idle-rss.sh` five times on both libcs, and `scripts/lib/perf_baseline.py` keeps each benchmark's mean and each RSS figure's median.
It commits the result to main as `perf/baselines/<version>.json`, with an `environment` field naming the runner.
The owner chose this on 2026-10-07 over hand-measuring each release, because the server releases several times a week and the hand step lapsed twice.

A runner is not the machine a deployment runs on, so a CI baseline's RSS is comparable only with another baseline from the same `environment`, never with the hand-measured ones from 0.38.0 and earlier, which carry no `environment` field.
For a question about real hardware, measure by hand as above and say so in the report rather than committing it as a baseline.

## Adding a new baseline

Nothing to do for a normal release: the `baseline` job commits it.
If a run failed or was skipped, run `perf.yml` by hand from main with the release's tag (`gh workflow run perf.yml -f tag=server-vX.Y.Z`); it measures that tag's commit and commits the file the same way.
`scripts/lib/test_perf_baseline_freshness.py` fails once the newest committed baseline falls more than a few releases behind the newest `server-v*` tag, so a missed run shows up.

## Measuring client cold start and idle memory

`scripts/measure-client-startup.sh` (repo root) times how long the client
takes to become interactive from a cold launch, and how much memory it holds
once idle.
It builds the web release, serves it locally, then drives a fresh headless
`google-chrome-stable` process against it over the Chrome DevTools Protocol
for each run (default 3), through `scripts/lib/client_startup_probe.py`.

**It measures the web build, not the Linux desktop build, and says so rather
than quietly substituting one for the other.**
The Linux target links GTK, and GTK needs a display connection to construct a
window even to run offscreen; this host carries no `Xvfb` and no passwordless
`sudo` to install one (checked directly, not assumed).
Headless Chrome opens no window on any display, on this host or otherwise,
which is what makes it a legitimate stand-in for "offscreen" rather than a
workaround for the hard "no visible window" rule.
The numbers it produces are real, but they are dart2js-plus-CanvasKit
booting inside V8, not the Linux GTK embedder's own native startup path, and
a Chrome tab's resident memory, not a native process's RSS - see
`docs/reports/perf-2026-08.md` for the actual figures and that distinction
stated again next to them.

Each run also measures headless Chrome against a bare `about:blank` tab
under the identical flags and reports the app's cost over that baseline,
the same control the Space analytics section of `CLAUDE.md` used for a
server measurement: Chrome's own multi-process overhead (a zygote, a GPU
process, several renderer helpers) turned out to dwarf the app's own cost
on this box, and reporting only the raw total would have buried the number
this script actually exists to answer.

Memory is read as Pss (`/proc/<pid>/smaps_rollup`), summed across the whole
process tree the launched Chrome spawns, not `VmRSS`: Chrome's processes
share large mappings (its own binary, the V8 snapshot, ICU data), and
summing `VmRSS` across them counts each shared page once per process. That
inflated a bare `about:blank` idle tree to an implausible 1.3 GB of summed
`VmRSS` on this box before the fix; `Pss` divides a shared page's cost across
every process mapping it, which is what makes the sum mean the tree's real
footprint.

**Not wired into CI**, for the same reason idle RSS is not: cold-start
timing and process-tree memory are both sensitive to what else a host is
doing while they run, and a shared, virtualized CI runner is a third
environment rather than a stand-in for a contributor's own machine or a
real deployment. A number captured there would look exactly as
authoritative as one taken by hand while measuring something noisier.

## Canvas fps and memory at target object counts

The Voice Canvas has its own benchmark machinery, from the Phase 5 spike,
under `client/packages/voice_canvas/benchmark/`: `spatial_grid_benchmark.dart`
(spatial-index query cost against a 16.6ms frame budget), `hot_path_benchmark
.dart` and `remote_draft_paint_benchmark.dart` (dispatch and paint cost
against the same budget, run via `flutter test` since they reach into
`dart:ui`), and `presence_benchmark.dart` (camera-bubble layout cost).
None of the four measured memory, so `canvas_memory_benchmark.dart` is new:
it builds a real `CanvasDocument` at the roadmap's own soft-cap object counts
(5,000 on iOS, 20,000 on Linux, `docs/ROADMAP.md`'s Phase 5 deliverable list)
and reads the `flutter_tester` process's own resident memory
(`dart:io`'s `ProcessInfo.currentRss`) before and after, the same "read the
real process, not a guess" preference the idle-RSS script above already
takes for the server.

Real numbers from all five, at the documented target counts, are in
`docs/reports/perf-2026-08.md` rather than duplicated here, since a number
in two places is a number that can disagree with itself.

**None of the five is wired into `perf.yml`, deliberately, past what already
runs.**
`client-ci`'s existing workspace-wide `dart analyze` already type-checks
every file under `benchmark/`, including the new one, on every pull request
touching `client/**` - confirmed directly rather than assumed: a
deliberately broken constructor call in `canvas_memory_benchmark.dart` was
caught by a plain `dart analyze` run with no new job needed. That already
closes the failure mode a compile-gate would exist to catch (the benchmark
machinery silently bit-rotting against the production API), for free, on
the existing schedule.
What a new CI job would add past that is asserting on the benchmarks' own
*numbers* - and those are exactly the class of measurement the idle-RSS
section above already declined to gate for: `canvas_memory_benchmark.dart`'s
own n=5,000 delta swung roughly 65% between independent runs on this one box
(see the report for the raw figures), because RSS tracks generational GC
arena growth as much as it tracks live object count.
A shared, virtualized CI runner under unpredictable scheduler contention is
a worse environment for that reading than this one, not a better one, so a
numeric assertion there would be exactly the flaky, falsely-authoritative
gate this file already argues against for the server.
