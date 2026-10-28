# CI and the release pipeline

Why the workflows in `.github/workflows/` are shaped the way they are.

A YAML file has no doc-comment mechanism, so a `#` block at the top of a workflow is the only thing it can carry, and this repo caps a plain comment elsewhere at one line.
Anything that needs more room than that lives here, and the workflow keeps a short note pointing at the section.
Each section below is named for its workflow file.

## Workflows at a glance

| Workflow | Runs on | What it gates |
| --- | --- | --- |
| `server-ci` | changes under `crates/` or `.sqlx/`, `schema/openapi.yaml`, the Cargo files, `rust-toolchain.toml`, `docker/server.Dockerfile`, or its own workflow file, and every merge queue entry (`merge_group`, which ignores path filters) | fmt, clippy, sqlx cache check, tests, release build, binary size budget |
| `client-ci` | changes under `client/`, or to `schema/openapi.yaml`, `scripts/desktop-shell-smoke.sh`, `scripts/chrome-tests.sh` or its own workflow file; `update-golden-references` also by hand (workflow_dispatch), and every merge queue entry (`merge_group`, which ignores path filters) | dart analyze and format in one job, every package's tests sharded across the `client tests` matrix, the web build in its own job, the `test and web build` aggregate that needs both (the name `release.yml` requires), and the pure-logic tests listed in `client/chrome-tests.txt` compiled to JavaScript and run in Chrome, so a typo reports in about a minute rather than fourteen; `update-golden-references` regenerates design_system's golden PNGs for a human to commit |
| `client-macos-ci` | a nightly schedule, and by hand | that the Dart and Swift compile against the macOS SDK. Compile-only, unsigned, and not a required check |
| `client-windows-ci` | pushes to `main` that touch `client/` or `packaging/windows/`, pull requests touching native Windows paths or the `client/pubspec.yaml` and `client/pubspec.lock` pins, a nightly schedule, and by hand | that the native plugin graph links against the Windows SDK, the Windows launcher's Go tests (after `go generate` embeds its icon), and that the Inno Setup script compiles. Compile-only, and not a required check. Run by hand with `tester_build`, it also uploads that ref's release zip and setup as a 7-day artifact for the win11 VM |
| `android-ci` | changes to the client pubspecs or lockfile, anything under a package's `android/`, the verification script, its own workflow file or `main-builds.yml`, on pull requests and pushes to `main`, and by hand (workflow_dispatch) | the Android release APK and app bundle build with Gradle dependency verification on, so a stale `verification-metadata.xml` fails before merge instead of in `main-builds`; no secrets (debug-signed, placeholder `google-services.json`). Regenerate with `scripts/android-verification-metadata.sh` |
| `client-ios-ci` | changes under `client/packages/app/ios/`, `rtc/`, `platform/`, `data/`, the pubspec files, on pull requests and pushes to `main` | every `Runner` source file is registered in `project.pbxproj` (ubuntu, always), the iOS CallKit XCTest and extension-embeds-no-frameworks checks on macOS, and an unsigned Release-configuration device build when a native-relevant path changed |
| `schema-ci` | changes under `schema/`, `redocly.yaml` on pull requests; every push to `main` unconditionally, and every merge queue entry (`merge_group`, which ignores path filters) | redocly lint, the additive-only oasdiff gate against a PR's base on pull requests, and the same gate against the immediate parent commit on every push to `main` (required for a release; see below) |
| `audio-ci` | changes under `assets/audio/` or the client's bundled copy in `client/packages/app/assets/audio/` | the sixteen interface sounds and the CallKit ringtone rebuild to the bytes that are committed, and the palette keeps its levels |
| `hygiene` | every pull request, and every push to `main`, and every merge queue entry (`merge_group`, which ignores path filters) | iOS purpose strings, the iOS broadcast extension is wired up, orientation is locked on phones only, no emoji in UI source, SPDX headers on Rust source, the file-size budget, the comment cap, the test-pattern ratchet, and the `scripts/lib` unit tests, which include the two structural gates on `required_checks` |
| `advisory-watchdog` | a daily schedule, and by hand | nothing. It opens a deduplicated GitHub issue for a security advisory against a dependency and closes it once the tree is clean; the trigger `licenses` deliberately does not carry |
| `licenses` | changes to any dependency manifest or lockfile or to `deny.toml`; every push to `main`, and every merge queue entry (`merge_group`, which ignores path filters) | every Rust crate's and every pub package's license is in the one allowlist |
| `sonar` | every pull request from this repository (a fork's PR has no secret to scan with) and every push to `main` | advisory SonarQube Cloud analysis (maintainability, duplication, complexity) under the `SONAR_TOKEN` secret, scoped by `sonar-project.properties`; never a required check |
| `load` | by hand only (workflow_dispatch) | nothing. It boots a disposable local server and runs one k6 scenario (`fanout`, `http_mix` or `connect_storm`) against it, optionally under a samply CPU profile, and uploads the results directory as an artifact. It refuses any non-loopback target and is never a PR check |
| `perf` | changes under `crates/`, `perf/`, the Cargo files; plus published `server-v*` releases, and `workflow_dispatch` with a tag to redo a missed one | benches compile on PRs; on a server release, benches plus five idle RSS runs on both libcs, committed to main as `perf/baselines/<version>.json` |
| `compose-smoke` | changes to the self-host stack, a weekly schedule, and by hand | `docker compose up` on a fresh box produces a working deployment |
| `e2e` | every push to `main`; a nightly schedule; by hand; and pull requests (opened, updated, reopened or marked ready for review, never while a draft) only when they touch voice, calls, the canvas, the rtc/api packages, server auth/ws/hub/voice, migrations, the image, the schema or the harness (a superseded PR run is cancelled) | the whole product through two real headless browsers; advisory, not required |
| `e2e-playwright` | every push to `main`; by hand; and the same path-gated, draft-skipping pull requests as `e2e` (opened, updated, reopened or marked ready for review), plus changes under `e2e/` (a superseded PR run is cancelled) | the product through two real browsers driven by Playwright Test, with a video of each user for every test; advisory, not required |
| `push-relay-contract` | changes to the server's push path, and by hand | a server-generated envelope through the relay repo's real HTTP handler |
| `verify-release-checks` | called by `release`, twice, once per component | that this exact commit's own CI completed and succeeded before any publish job runs, on both the release-please and the by-hand tag paths |
| `copr-catch-up` | a completed `main-builds` run on `main` (any conclusion, cancelled included), a six-hourly schedule, and by hand | submits the client to COPR only when COPR's newest live build is older than `client/pubspec.yaml`, so a `main-builds` run cancelled by a merge storm no longer strands the Linux client; does nothing when COPR is current |
| `web-image` | called by `main-builds` (a client change), by `release` (a server release), and by `publish-paths` with `publish: false` (build only) | the web client built into a signed multi-arch `ghcr.io/<owner>/slim-m-web` image, split out into its own file because `main-builds` is at the 500-line ceiling |
| `server-binaries` | called by `release` and by `publish-paths`, or dispatched by hand to check both arches build | the static musl server binaries per arch, uploaded as run artifacts for `server-release-assets`, split out into its own file because `release` is past the 500-line budget |
| `publish-paths` | pull requests that edit a publish recipe: the release, main-builds, server-binaries and web-image workflows, `docker/`, the Cargo and toolchain files, `client/pubspec.lock` | builds the release's server binaries, both server images and both web images from the same workflows the release uses, and publishes nothing, so a broken recipe fails on its PR instead of on the release (server-v0.84.0's arm64 binary) |
| `copr-publish` | called by `main-builds` and `copr-catch-up` | the Fedora COPR snapshot submission, split out into its own file once `main-builds` hit the 500-line ceiling; a failed submit is retried up to three times and then fails the job |
| `desktop-clients` | `client-v*` tag pushes, and by hand with a tag input | unsigned Windows and macOS tester archives, attached to the client's GitHub release, with the Windows launcher built (icon generated, linker `.lib` and `.exp` files dropped from the bundle) and its Go tests run on the way, then the signed `update-manifest` job. The two desktop platforms `release` does not package |
| `client-checksums` | called by `release` after the Linux and Android jobs and by `desktop-clients` after its archives attach, and by hand with a tag input | writes one `SHA256SUMS` (and `SHA256SUMS.asc` when the GPG secret is set) over every client download attached to the release: Linux tarball, flatpak, rpm, Windows zip and setup, macOS zip and the apk. Writes only once the tarball, Windows zip, setup and macOS zip are all attached, whichever caller finishes last |
| `update-manifest` | called by `desktop-clients` after its archives attach and by `release` after the Linux tarball attaches, and by hand with a tag input | signs a manifest (versions, artifact URLs, sha256s) of the desktop artifacts on a client release with the `UPDATE_SIGNING_KEY` secret, for the self-updater in decision 0041. Signs only once every platform (`windows-x64`, `macos`, `linux-x64`) is attached, whichever producer finishes last. Fails when the secret is unset, because a client release with no signed manifest cannot be updated to |
| `release` | pushes to `main`, and by hand on a `server-v*` / `client-v*` tag ref | the whole publish pipeline, including the web image under the server's version |
| `release-tag-watchdog` | an hourly schedule, and by hand | every release-please manifest's version has a matching git tag, catching a release PR that merged with no tag ever following it, and no merged release PR is still labelled `autorelease: pending`, which silently fails every later release run; and, in a second job, re-dispatches `release.yml` on the tag once when the release run's verify failed and the commit's required checks have since gone green |
| `release-asset-watchdog` | an hourly schedule, and by hand | nothing. It checks every `client-v*` and `server-v*` release from the last 3 days against the asset set its kind always carries, and opens a deduplicated `release-incomplete` issue (and fails its own run) when one older than 90 minutes is missing a file, or when its `manifest.json` omits a platform whose asset is attached |
| `red-streak-watchdog` | a daily schedule, and by hand | opens a GitHub issue once `e2e` or `main-builds` has failed 3 consecutive completed runs on `main`, closes it once that workflow is green again; does not gate anything |
| `main-builds` | changes under `client/`, `crates/`, `packaging/`, the Cargo files, `rust-toolchain.toml`, `docker/server.Dockerfile`, `.sqlx/`, the web image's own files, the local actions and reusable workflows it calls, or its own workflow file, on every push to `main`, excluding a release commit's own files; and by hand, with a boolean per side | a Fedora COPR snapshot, an Android artifact, `latest` on the live server image, `latest` on the web image after a client change, and continuous TestFlight unless the repo variable `CONTINUOUS_TESTFLIGHT` is `false`, in which case iOS builds only from a client release in `release`, or when this is run by hand; never a version bump, changelog or GitHub Release |
| `flatpak-ci` | changes to the flatpak manifest or its vendored shared-modules, on pull requests and every push to `main`; and by hand | builds the flatpak for real, installs it, and checks a headless launch does not fail with a missing shared library, the failure class `release.yml` cannot catch before a `client-v*` tag |

## Keeping this table honest

Two gates in the `scripts/lib` unittest suite watch the table above, because CLAUDE.md sends readers here as the authoritative workflow list and a row that is wrong is worse than a row that is missing.

`scripts/check-ci-docs.py` enforces that every workflow has a row and every row names a real workflow file. It reads nothing inside the row, so for a long time the "Runs on" column could describe a trigger a workflow did not have, or omit one it did, with the gate green.

`scripts/lib/test_ci_docs_triggers.py` covers that next layer: a row for a workflow with a `schedule:` has to say so, and one with `workflow_dispatch:` has to admit it can be run by hand.
The rest of the column is prose and not mechanically checkable, but an omitted trigger kind is a factual gap rather than a wording choice.
Two rows had omitted `workflow_dispatch` before this existed.

It checks every workflow yields at least one trigger kind, per file rather than in aggregate: a workflow whose `on:` block drifts out of the parser's reach would otherwise be silently exempt while the other twenty keep the suite green.

## Job timeouts

Every job sets `timeout-minutes`, sized at roughly two to three times its slowest recent successful run, so a hung apt mirror or simulator cannot hold a required check, a release or a macOS runner for GitHub's six hour default.
A job that calls a reusable workflow cannot carry the key; the callee's jobs do.
`scripts/lib/test_every_workflow_job_has_a_timeout.py` fails when a job has none.
Raise a job's limit when its real runtime grows toward it, rather than removing it.

## server-ci

Path-gated so a client-only change never triggers a server build.

`schema/openapi.yaml` is in the path filter even though it is not Rust.
`crates/slimm-server/tests/openapi_contract.rs` gates the schema against the router, so a schema-only edit that documents a path nothing serves, without touching `crates/`, must still run that test.
`crates/slimm-server/tests/response_contract/` goes further and validates real response bodies against the document, including refusals: one representative case per documented error status, since `Error` is the same object on every route.
Before that, every non-2xx returned before the schema was consulted, so an error body that had drifted from `Error` passed every gate here.

Details, in [ci-details.md](ci-details.md#server-ci): The Rust compiler is pinned; The sqlx cache; Unused dependencies.

## client-ci

Path-gated so a server-only or schema-only change never triggers the Flutter client build.

Details, in [ci-details.md](ci-details.md#client-ci): The web bundle budget; The app shards are dealt by measured time; Native build hooks are cached, and explain their own failures; Logic tests also run as JavaScript; Where a pull request's time goes, measured 2026-10-02; Runner labels are pinned; Goldens are not a separate job; The iOS unit-test job, and why it is its own workflow; The registration and release-configuration checks, and why PR #292 needed both.

## schema-ci

`oasdiff breaking` reports only changes that break existing clients: removed paths and fields, narrowed types, newly required properties, and similar.
Purely additive changes such as a new optional field or a new endpoint are not breaking and pass, which is what makes this gate additive-only by construction.

Two jobs run it, against two different bases, because one commit needs both.

`schema/oasdiff-err-ignore.txt` lists intentional breaks, one literal oasdiff line per finding (a removed route, a response enum that gained a value); both jobs pass it as `err-ignore`.
The match is exact text, not a regex, so each entry names one finding and an unlisted break still fails.
Entries are harmless once merged and can be pruned.

`breaking-change-gate` runs on `pull_request` and diffs the PR's base against its head - the meaningful comparison for a reviewer, and the one that can catch a breaking change before it ever reaches `main`.
The PR's head commit is checked out explicitly rather than the default merge-ref checkout, so `HEAD:schema/openapi.yaml` is exactly the schema the PR proposes with no synthetic merge commit in between.
oasdiff also needs the base branch's schema content, but that checkout only fetched the PR head commit, so the workflow fetches just that one base commit, shallowly, by its exact SHA from the `pull_request` event payload, landing it in the local object database without cloning the base branch's history.
oasdiff then reads it straight out of git as `<base-sha>:schema/openapi.yaml`.
That commit is the merge base of the PR and its base branch, found by `scripts/pr-merge-base.sh`, not the base branch's tip: against the tip, a path that `main` gained after the PR branched reads as removed by the PR, and the gate goes red for a change its author never made.

`breaking-change-gate-main` runs on every push to `main` instead, diffing `HEAD~1` against `HEAD`.
This is not redundant with the PR-time gate: `verify-release-checks.yml` (see below) polls check-runs on the exact commit a release verifies, a squash-merge mints a brand-new SHA that the PR-time gate's check-run was never attached to, and a release-please commit never touches `schema/**` at all - so `breaking-change-gate` structurally cannot ever appear on the commit a release actually checks, no matter how the required-checks list is written.
`breaking-change-gate-main` is what can: it is unconditioned on any path filter and runs on literally every push to `main`, trivially passing (an empty diff) on the overwhelming majority that never touch `schema/openapi.yaml` at all.
This relies on this repo's squash-merge-only convention (see "Contribution conventions" in `CLAUDE.md`): `HEAD~1` is exactly the one commit a merged PR added.
A direct multi-commit push to `main` bypassing that convention would only diff the last of them; not a concern under the convention this repo actually follows, and not worth the added complexity of walking further back for a case that should not happen.

Details, in [ci-details.md](ci-details.md#schema-ci): OpenAPI 3.0 `nullable` in a 3.1 schema.

## hygiene

Most of its gates run through `scripts/gates.sh`, the same command to run locally (after `git add`, since gates skip untracked files).
The PR title check, actionlint and shellcheck are separate steps.

Details, in [ci-details.md](ci-details.md#hygiene): The shell, which nothing checked until 2026-09-11; The e2e harness's own unit tests; iOS purpose strings; The iOS broadcast extension is wired up; Orientation is locked on phones only; No emoji in UI source; SPDX headers on Rust source; The file-size budget; The comment cap.

## licenses

Two jobs, one policy.
`deny.toml` holds the allowlist; cargo-deny reads it directly for the Rust tree and `scripts/check-dart-licenses.py` reads the same `[licenses]` table for the Dart tree.
One file rather than two, because the failure this gate exists to catch is a copyleft dependency arriving quietly in the client, and two policies that can drift is how that arrives.

It is not part of `hygiene` because both halves need a toolchain.
`hygiene` is the seconds-long grep job that runs on every push with nothing installed, and a cargo metadata resolve plus a `flutter pub get` would turn that into minutes.
So it is path-gated on the manifests, the lockfiles and the policy, plus every push to `main` whatever changed.

Details, in [ci-details.md](ci-details.md#licenses): What is allowed, and what is not; The Dart half, and why it reads license text.

## perf

Path-gated to server and perf-scaffolding changes.
GitHub Actions does not support path filters on the `release` event, so the release-triggered job is not path-gated; it runs once per published release, except that it skips the `schema-v*` release the server config cuts alongside each server release.

`compile-gate` is a fast compile-only gate on every pull request: it proves the benchmarks still build without paying for a full measurement run on each push.

`benchmark` runs the real benchmarks once a release is published and uploads the criterion report as a workflow artifact, for hand-curation into a new `perf/baselines/<version>.json` (see `perf/README.md`).
It has no environment gate, and that is deliberate: it uploads only an intra-run workflow artifact, not a published release asset, so it is exempt for the same reason the release workflow's `server-binaries` build stage is.
Reviewer-gated Environments are applied at the true publish boundary (GHCR push, release assets, TestFlight), not to build-time artifacts.
No secrets are used.


## load

`load.yml` is `workflow_dispatch` only: it saturates a runner on purpose and gates nothing, so it is neither a PR check nor scheduled.
A weekly run was considered and left out, because nothing reads the result and a shared 4-core runner is too noisy to compare week to week.
The inputs are the scenario, a `KEY=VALUE` sizes string (validated to digits, then handed to k6 as `-e` flags) and a profile toggle.
They reach the steps through `env:`, never pasted into the script.
The job runs `scripts/load-run.sh`, which boots a local server and refuses any non-loopback target, then uploads `perf/load/results` as an artifact.
See `perf/load/README.md` for the scenarios and how to read the results.

## compose-smoke

The self-host stack is the product for most people, and nothing was checking that it boots.
Every other gate tests the server, the client or the schema in isolation; this one asks whether `docker compose up` on a fresh box actually produces a working deployment, which is the thing a self-hoster does first and the thing most likely to rot silently when a service is added.

It runs on changes to the stack itself and on a weekly schedule, because the failure mode it catches is usually an upstream image moving rather than a commit here.

Details, in [ci-details.md](ci-details.md#compose-smoke): Building the image locally; Text chat on its own, which is the default; Refusing to start without LiveKit credentials; What the smoke run covers, and why only part of the stack.

## e2e

`scripts/e2e.sh` is the most comprehensive check in the repository, and until this workflow it ran nowhere.
`grep -rln e2e .github/workflows/` returned nothing, so it gated nothing and had been failing since the settings restructure in #142 with no signal at all, found only by running it by hand.
A gate nobody runs is not a gate, which is the whole reason this workflow exists.

It builds the release server binary from source, builds a real Flutter web bundle, and runs a LiveKit dev-mode SFU in Docker, all inside the one job.
Nothing here is pulled pre-built, other than the pinned third-party actions and the LiveKit image itself.
`E2E_REBUILD=1` is set explicitly so the web bundle is always built fresh from the checked-out commit.
A cached build silently screenshots stale code instead, which has cost a confused debugging cycle before (see `CLAUDE.md`).
Chrome is not installed by this workflow: `ubuntu-24.04` ships Google Chrome already, and the harness's own prerequisite checks fail loudly and by name if a future runner image ever drops it.
The only Python dependency beyond the standard library is `websocket-client`, since the harness drives Chrome directly over the DevTools Protocol rather than through Selenium or a browser driver.

Not path-gated, on purpose, unlike every other workflow here: it runs on every push to `main` regardless of what changed.
It is the one check that exercises the client, the server and the schema together, and a change confined to any one of those areas can still break a scenario the narrower, path-gated gates never see.
It is also not run on pull requests at all: a full run is too slow and drives too much real infrastructure to pay for on every PR, and the faster per-area workflows already gate a PR on its own area.
A nightly schedule and `workflow_dispatch` cover the gap that leaves.
A slow drift, such as a renamed label or a restructured settings screen, is caught within a day instead of only whenever somebody happens to run the script by hand, and a person can still trigger a run on demand without waiting for either.

**It is advisory, not required, until it has proven itself.**
Browser automation can be flaky for reasons that have nothing to do with the change under test, and a red check nobody trusts teaches people to ignore CI rather than read it.
Nothing in this workflow blocks a merge or a release: `verify-release-checks.yml`'s required-check list (see the `release` section below) does not name it.
Promote it once real runs on `main` show it green and stable, which takes more than one run to judge given the class of flakiness a real browser and a real SFU can introduce; add its job to branch protection, and to `required_checks` in `verify-release-checks.yml` if it should also gate a release.

Screenshots (`E2E_SHOTS`, one per interesting moment, plus one at the point any scenario gives up) upload as the `e2e-evidence` artifact on every run, not only on failure, since a passing run's screenshots are still useful evidence.
The browser's own console log goes up beside each failure screenshot, and the server's log with them.
That is not padding: the first real run on a runner (30565517095) failed nine scenarios and the screenshots could show only that a channel list was empty, while what settled it was a pair of 404s nothing was capturing. See `docs/e2e.md`.

See `docs/e2e.md` for what the harness actually covers and what it does not.

Details, in [ci-details.md](ci-details.md#e2e): e2e-playwright runs the same stack under Playwright Test; red-streak-watchdog closes the "advisory and nobody is watching" gap this section already names.

## push-relay-contract

The server and the relay agree on the push envelope's wire framing (field names, types, the platform and kind vocabulary, the payload size limit) but live in separate repos and languages, so nothing else here would notice one side changing it.
This is the only job that checks out both and runs a server-produced request through the relay's real HTTP handler.
See `crates/slimm-server/tests/push_relay_contract_fixture.rs` and slim-m-relay's `internal/api/push_relay_contract_test.go`.
The fixture it hands the relay holds `message` entries only, because the relay's test counts them against its own case table.
The same run also writes `push_relay_contract_kinds.generated.json` beside it, with one entry per other kind produced through the server's own path for it (`mention`, `call` on Android and on the iOS VoIP token, `call_end`, `security`), and asserts each entry's shape and sealed envelope in server CI.
The relay ignores that file until its own test adopts it, so a wire-name drift in those kinds fails on this side first.
The relay is checked out from this repository's own owner (`github.repository_owner`), so the two repos have to live under the same owner.

Details, in [ci-details.md](ci-details.md#push-relay-contract): No `token:` input on the relay checkout; Three ways this job could go green having asserted nothing.

## release

The full release and publish pipeline.
The steps of `linux-client`, `android-client`, `ios-testflight` and the COPR submit live in the `release-*` composite actions under `.github/actions/`, so `release.yml` stays under the file budget.
The jobs keep their `environment`, secrets, `needs` and `if:` gates; a composite cannot read those, so the version, tag and tokens arrive as inputs and the signing secrets as the job's env.

Details, in [ci-details.md](ci-details.md#release): How a release is cut; The schema package cuts its own tag; The release PR's own checks; Gating publish on the commit's own CI; A queued run is not an in-flight run; release-tag-watchdog closes the detection gap the fix alone leaves open; The watchdog re-dispatches a release that verify timed out on; server-image and server-image-merge; server-binaries and server-release-assets; linux-client; copr; android-client; ios-testflight; Build numbers and build names, on both mobile jobs.

## client-macos-ci and client-windows-ci

Both are compile-only, both are deliberately not required checks, and both exist to catch a native break early rather than to prove the app works.
Because they gate nothing, neither runs on every pull request: `client-macos-ci` is nightly and manual, and `client-windows-ci` runs on pushes to `main`, nightly, and PRs touching native Windows files.
The macOS runner pool is five jobs, so this keeps slots free for the release's `ios-testflight` job; a native break now shows up within a day rather than on the PR.
`client-ios-ci` is the one that gates a release, so it stays, but its push trigger uses the same native-path filter as its pull request trigger; the release commit still matches it through the pubspec bump, which is what `verify-release-checks` waits for.

`client-macos-ci` builds `client/packages/app/macos/`, which is still a fresh `flutter create` scaffold with no signing identity, no notarization credential and no Apple Developer team behind it.
It builds `--debug` on this project's SPM-only plugin tree with no CocoaPods step, exactly as `client-ios-ci` does, which produces a local "Sign to Run Locally" binary needing no Apple account.
`docs/os_backlog/macos_backlog.md` holds what a distributable build still needs.
It also runs the macOS self-update install tests, because that file's last test is the only one that drives the real `ditto`, `xattr` and `codesign` and it skips everywhere else.

`client-windows-ci` is the first CI job that has ever built a Windows target here.
A green run proves the native plugin graph links; it does not prove the app runs, looks right, or that the tray and window-shell behaviour decision 0012 designed works on a real desktop.
Read `docs/os_backlog/windows_backlog.md` before promoting it to a required check or building anything on top of a green run.

## advisory-watchdog

`licenses` runs `cargo deny check licenses` and deliberately not `check all`, because a CVE published upstream would turn every unrelated pull request red through no fault of its own.
That reasoning names a different trigger as the answer, and this is it.

It gates nothing, and it does not report by its own colour: a scheduled workflow that only fails itself is a red tab nobody opens, which is the failure `red-streak-watchdog` already exists to correct.
It opens a deduplicated GitHub issue instead, and closes it once the tree is clean again.

## client-checksums

`linux-client` still writes a first `SHA256SUMS` of the tarball, flatpak and rpm, because that file existed before the other downloads did.
The Windows zip, the setup exe and the macOS zip are attached by `desktop-clients`, so a checksum file written in `release` alone could never list them.
`client-checksums` is a reusable workflow that downloads the downloads actually attached to the release, hashes them and overwrites `SHA256SUMS`, so the file lists what is there rather than what one job built.
`release` calls it after `linux-client` and `android-client`, and `desktop-clients` calls it after its two archive jobs.
A call that finds the tarball, Windows zip, setup or macOS zip missing writes nothing and passes with a notice, so the caller that attaches the last one writes the full file.
`release`'s call needs `linux-client` and names its result in its `if:` (`scripts/lib/test_conditional_jobs_keep_their_needs_gate.py`), which also makes it the last writer after `linux-client` re-uploads its partial file.
Calls for one tag are serialised by a concurrency group, and the run that starts last always sees every earlier attach.
It uploads with `RELEASE_PLEASE_TOKEN` when set, as `linux-client` does, because a release created with that token refuses uploads from the workflow token.
`SHA256SUMS.android` is still written by `android-client`, because `scripts/check-release-assets.py` requires it; the apk is in the combined file too.
By hand it takes a `tag`, which is how to backfill an older release.

## release-asset-watchdog

release-please publishes the GitHub Release before any asset job runs, so a release is public, and `latest`, from the first second while its builds can still fail.
Client 0.89.0 shipped that way on 2026-09-30: the Windows job failed, `update-manifest` skipped behind it, and the release had no Windows zip and no `manifest.json` until a hand dispatch backfilled them an hour later.
Nothing noticed, because `verify-release-checks` judges check-runs before publish and `update-manifest.py --require` only runs inside the job that was skipped.

`scripts/check-release-assets.py` lists releases through `gh api` (GET only) and compares each release's asset names with the set for its kind, kept in one `REQUIRED` table in the script.
A `client-v*` release must hold `manifest.json`, `manifest.json.sig`, `SHA256SUMS`, `SHA256SUMS.android`, the rpm, the linux tarball, the flatpak, the macOS and Windows zips and the apk.
A `client-v*` release whose `manifest.json` leaves out a platform whose archive is attached is incomplete too, because the manifest is what the self-updater trusts.
The script downloads the manifest to read its platform list.
A `server-v*` release must hold `SHA256SUMS` and the linux amd64 and arm64 binaries.
`schema-v*` tags are anchors with no assets by design and are ignored.
Names that carry the version are patterns filled from the tag, and an asset with size 0 counts as absent.
The sets were derived from `client-v0.89.0` (10 assets) and `server-v0.77.0` (3), not from memory; change the table when a workflow changes what it attaches.

A release younger than the grace period (90 minutes, `--grace-minutes`) is reported as pending and does not fail, since the asset jobs take about an hour.
The workflow runs the script hourly over `--recent 3` days and hands the result to `scripts/report-advisory-issue.sh`, the same open, dedupe and close flow `advisory-watchdog` uses, with the label `release-incomplete`.
Unlike the advisory check it also fails its own run, because an incomplete release is something to act on rather than to read later.
Releases older than the window are not rechecked, so a release left incomplete for more than 3 days stops alerting; run the script by hand with `--recent` for a longer look.
`scripts/lib/test_check_release_assets.py` drives the comparison with fake asset lists.
The scan step pipes the checker into `tee` under `set -euo pipefail`: a step with no `shell:` runs `bash -e`, where tee's exit 0 replaced the checker's exit 1, so `steps.scan.outcome` was always `success` and neither the issue nor the red run could ever appear.
`scripts/lib/test_release_asset_watchdog_fails_on_missing_assets.py` runs the workflow's own step text against a fake `gh` with the shell flags GitHub would pick, and refuses a pipe into `tee` without pipefail in any workflow.

The run itself now fails where it can know.
`release.yml` attaches assets through `scripts/upload-release-assets.sh`, which retries a failed upload (five attempts, growing pauses, the PAT's remaining core API budget in the final error) and fails the job when a required file pattern matches nothing, where softprops uploaded whatever matched and went green.
Only the flatpak and the rpm globs are optional at upload time, so the tarball and checksums still attach, and a last `verify flatpak bundle was produced` step then turns the job red.
That step was `continue-on-error` and could never fail a run.
`update-manifest` fails rather than warns when `UPDATE_SIGNING_KEY` is unset.
The hourly watchdog stays the net for what the run cannot see, such as the Windows zip, which a different workflow attaches.
Not done here: the COPR jobs stay best effort, and the signing key stays a repository secret, because moving it behind the `release` environment needs the owner to scope the secret and set reviewers.

## verify-release-checks

Called twice from `release`, once per component, so every publish job - a GHCR push, a cosign signature, a GitHub Release asset, a Play or TestFlight upload - requires this exact commit's own CI to have completed and succeeded first.

Before it existed, the tag path published unconditionally with no test workflow having run on that ref at all, straight into a deployment that auto-updates from the moving `latest` tag.

`workflow_run` cannot do this job: it fires only when a named workflow completes for the event that triggered it, and none of `server-ci`, `client-ci`, `client-ios-ci`, `hygiene` or `licenses` trigger on a tag push, deliberately, to avoid re-running CI on a ref that already ran it on `main`.

The `ref` input carries the sharp edge.
It defaults to `github.sha`, which is right for the by-hand dispatch on a tag ref, but the release-please path must pass the created tag instead: release-please acts on the repository's current state while `github.sha` is whatever commit started the run, and the two diverge whenever a release merge lands while an earlier run is still going.
Verifying `github.sha` then waits on a check a path filter correctly skipped, times out, and skips every publish job behind it, which is what happened to server 0.23.0 on 2026-08-01.
The publish jobs follow the same rule: `release-please` exports `server_ref` and `client_ref` (the commit each tag sits on, `github.sha` on a by-hand run), and every publish checkout, `SLIMM_BUILD_ID` and `sha-` tag uses them, with `web-image` and `server-binaries` taking a `ref` input.
`scripts/lib/test_release_publishes_the_commit_it_verified.py` fails on a publish checkout without one.
The version and tag come from the same place: `release-please` outputs `server_version`, `server_tag`, `client_version` and `client_tag`, falling back to the tag a by-hand run names, so no publish job strips a `server-v` or `client-v` prefix itself (`scripts/lib/test_release_resolves_versions_once.py`).
The Flutter version is spelled in every workflow, the `linux-tarball` action and `docker/web.Dockerfile`; `scripts/lib/test_flutter_version_is_pinned_once.py` fails if any of them disagree.
A check run is attached to the commit, not to the event, so polling the commit's check-runs answers both trigger paths the same way.
The names in `required_checks` are matched exactly, so a job renamed in `server-ci` or `client-ci` without the matching edit here blocks every release, which is the safe direction to fail.
The deadline covers queueing, not running: client 0.23.0 timed out at the old thirty-minute ceiling with `client-ios-ci` still queued, and that check passed minutes later.

## web-image

Builds `docker/web.Dockerfile` into `ghcr.io/<owner>/slim-m-web`: `flutter build web --release --base-href /app/ --no-web-resources-cdn` at the pinned Flutter version (CanvasKit is served from the image, not gstatic), behind the unprivileged nginx image (`docker/web-nginx.conf`, with a CSP, frame and nosniff headers from `docker/web-security-headers.conf`), which runs as a non-root user on port 8080.
It is a reusable workflow with one input, the newline-separated tags for the merged manifest, and it has the same shape as `server-image` and `server-image-merge`: one image per architecture on a native runner, pushed by digest with an SBOM and provenance, then merged and cosign-signed keylessly.
The merge job checks it got two digests, so a failed arch cannot ship a single-arch manifest.

Two callers.
`main-builds` calls it on a client change with `sha-<commit>`, `main` and `latest`, and Watchtower on the live host follows `latest`.
`release` calls it after `server-image-merge` with the server version as the only tag, so `SLIMM_VERSION` pins both images to the same release and `latest` never moves from a release.
A server-only merge does not rebuild it, because nothing in the bundle changed.

The build id is the commit sha.
It is compiled into the bundle (`--dart-define=SLIMM_WEB_BUILD`), written to `version.json`, and appended as `?v=<sha>` to `flutter_bootstrap.js` and `main.dart.js`, so a new build is a new URL for the one large file.
The Dockerfile fails the build if either rewrite did not match, since a silent miss would serve a stale bundle from a cache.
The page polls `version.json` and shows a reload pill when the id differs (decision 0025).

Details, in [ci-details.md](ci-details.md#web-image): Spotify client id.

## copr-publish

The Fedora COPR snapshot submission `main-builds` and `copr-catch-up` call, pulled into its own file once that workflow reached the 500-line hard ceiling.

A submit that is attempted and fails goes red.
It is tried up to three times with a 30 and 60 second backoff, so a transient COPR outage still passes, while an authentication or expiry error fails at once because a retry cannot help.
A missing `COPR_CONFIG` or spec file is still a warning and a skip.
The release path's own `copr` job (see `desktop-clients`) keeps its warning, since the release has already published by then.

A reusable workflow rather than a composite action, because it needs its own container image (`fedora:44`), which a composite action cannot declare.

## copr-catch-up

Linux clients update through the COPR repo `nc1107/slim-m`, which `dnf upgrade` tracks, and COPR is fed by `main-builds` (snapshots) and `release` (tagged builds).
Both are single event-driven paths: on 2026-09-25 a merge storm cancelled four `main-builds` runs before their `copr` job finished, COPR stayed on 0.84.0 while main reached 0.86.0, and nothing was red.

This workflow is the self-healing layer.
`scripts/copr-behind.sh` asks COPR's own API (`api_3/build/list`, filtered to `slim-m-client`) for the newest build that has not failed or been canceled, and compares its Version part to `client/pubspec.yaml` with `sort -V`.
Only when COPR is behind does the workflow build the tarball (the `linux-tarball` composite action, shared with `main-builds`' `linux-client`) and submit it through `copr-publish.yml`, the same submit steps and the same `COPR_CONFIG` secret `main-builds` uses.

Triggers:

- `workflow_run` on `main-builds` completing, any conclusion.
  A cancelled run still completes, so this fires exactly in the storm case; the last run of a storm is never cancelled, so at least one check happens after the dust settles.
  It is not `push`, because a release-commit push is excluded from `main-builds` and would race it.
- A six-hourly schedule as a backstop for what has no `main-builds` run to follow, such as a release PR merge (its bump files are path-excluded) or a failed submit.
- `workflow_dispatch`, to catch up on demand.

Idempotence rests on counting pending and running builds as current, so a check that lands while `main-builds` has just submitted does nothing; a build that failed or was canceled does not count, so the next trigger retries it.
A submit that `copr-publish` attempts and fails is retried, then fails the job (see `copr-publish`), and the next trigger heals it because a failed build does not count as current.

The concurrency group `copr-catch-up` has `cancel-in-progress: false`: a submit must never be killed halfway.
GitHub keeps one pending run and replaces older pending ones, which is fine here because every run asks the same question of COPR's current state rather than carrying a payload.

Version ordering comes from `copr-publish`, which stamps the snapshot Release from the commit (see the versioning section under `main-builds`), not from either workflow's run counter, so a catch-up cannot outrank a later `main-builds` snapshot of a newer commit.
A catch-up only submits a Version COPR does not yet have, so it does not collide with a snapshot of the same Version either.

## desktop-clients

The two desktop platforms `release` does not package: iOS goes through TestFlight, Android attaches an apk (no aab), and `linux-client` ships a tarball, an rpm and a flatpak, all from `release` itself.
This fills the gap with unsigned archives good enough to hand a tester, without touching `release`'s gated publish jobs.
The Windows zip also carries the `slim-m.exe` launcher built from `packaging/windows/launcher`, `install.cmd` and `install.ps1` for the first per-user install, and a `VERSION` file (decision 0041).
The same job compiles `packaging/windows/slim-m.iss` with a pinned, checksummed Inno Setup (the `install-inno-setup` action) into `slim-m-setup-<version>.exe` and attaches it beside the zip.

Unsigned is a stated trade rather than an oversight.
Windows has no signing certificate anywhere in this project, so SmartScreen shows "unrecognized app" and the tester clicks through.
The macOS app is ad-hoc signed by the build itself, so Gatekeeper quarantines a downloaded copy and a tester opens it with right-click Open, or strips the attribute with `xattr -d com.apple.quarantine`.

Both jobs declare `environment: release`, matching every asset-publishing job in `release`.
They are tag-triggered, so unlike `main-builds` they should sit behind a reviewer gate if one is ever added; `main-builds` documents its own opt-out for the opposite reason, that a continuous build must not block on review.

Details, in [ci-details.md](ci-details.md#desktop-clients): The Windows build runs under pwsh, and the one release that shipped without it.

## update-manifest

Groundwork for the per-user, signed self-update in `docs/decisions/0041`.
It downloads the desktop artifacts already attached to a client release (the Linux tarball from `release`, the Windows and macOS archives from `desktop-clients`), builds a manifest of them with `scripts/update-manifest.py`, signs it with ed25519, checks the signature against the key's own public half, and attaches `manifest.json` and `manifest.json.sig` to the release.
The desktop client fetches it and its signature from the release, verifies them, and only then downloads an artifact (`client/packages/app/lib/src/desktop/self_update/self_update.dart`), so a release without a manifest is a release nothing can update to.

It is a reusable workflow rather than steps inside `release` because `release.yml` sits near its line budget, and `desktop-clients` is the one workflow that knows when the Windows and macOS archives are attached.
The three archives come from two workflows that finish in no fixed order: `release` attaches the Linux tarball and `desktop-clients` the Windows and macOS archives.
Both call this workflow with `defer: true` and the default `require` of `windows-x64,macos,linux-x64`.
With `defer`, a call that finds a required archive not attached yet signs nothing and passes with a notice, and the producer that attaches the last archive signs the full manifest.
The `update-manifest` job in `release` needs `linux-client` and names its result in its `if:` (`scripts/lib/test_conditional_jobs_keep_their_needs_gate.py`).
Client 0.88.0 shipped a manifest without `linux-x64` because the only caller ran before the tarball existed; the Linux tarball updater then found no artifact for its platform.
By hand it takes a `tag`, a `require` list and `defer`, which is how to backfill a release.
Without `defer` a missing required platform fails the run.

The secret is `UPDATE_SIGNING_KEY`, an ed25519 private key in PKCS8 PEM form, stored as a repository secret.
While it is unset the job fails, unlike `copr-publish` without `COPR_CONFIG`: a green run that attached no manifest is how 0.89.0 shipped with none, and every caller runs on a client tag.
The owner's one-time key generation is in the decision record.
`scripts/lib/test_update_manifest.py` covers build, sign and verify, tampering, wrong key, swapped artifacts and rollback against a throwaway key generated per run.

## main-builds

The owner's own framing: "every time I go to main, I should be able to test on all devices that have changes... if I change the way voice canvas works and we take a PR to main, in 20 minutes or so I should automatically have an iOS release and Fedora PC should have the update also, with no extra touching involved."
This is the workflow that answers that, deliberately kept out of `release.yml`: that workflow's whole shape keys off release-please outputs and tag refs, and mixing an untagged path into it would make both harder to reason about.
Nothing here is versioned, changelogged, tagged or attached to a GitHub Release; that stays `release`'s job, triggered the same way it always has been by merging a release PR.
On a client merge, iOS reaches TestFlight and the owner's Fedora desktop gets a new build through the same COPR project `dnf upgrade` already polls; on a server merge, the live instance updates on its own, because `latest` moves.
A tagged release does not supersede its own version's snapshots on `dnf upgrade`, because a snapshot is newer code (see the versioning section below), but the next version's release outranks them all, and a release alone attaches signed assets to the GitHub release.

Details, in [ci-details.md](ci-details.md#main-builds): What triggers it, and the one filter step that replaces two workflows; What each side does; Fedora, COPR, and the two problems a snapshot build has that a release does not; Secrets, gating, and the environments it deliberately does not use; Concurrency, and why it is the opposite of `release.yml`.

## flatpak-ci

The gap this closes: before it existed, nothing in CI ever built the flatpak except `release.yml`'s `linux-client` job, which only runs at `client-v*` tag time (or when release-please has just cut a client release).
`desktop-clients.yml` is tag-only too, for Windows and macOS.
`main-builds.yml` lists `packaging/**` in its own trigger, but never builds the flatpak at all, on any push; it only builds the rpm and the tarball, and even that was silently skipped for a packaging-only commit until the `changes`-job fix described above.
So a broken flatpak manifest reached `main` and shipped to whoever installed client 0.60.x through Flatpak before anything caught it: PR #964 fixed the underlying defect (`media_kit_video`'s Linux plugin has a hard `NEEDED` entry on `libmpv.so.2`, which the freedesktop 25.08 runtime does not carry, so the app failed to launch at all), and PR #964 itself passed with only SonarCloud and hygiene as checks.

Details, in [ci-details.md](ci-details.md#flatpak-ci): Why a full build, not a manifest lint; Why gated narrowly on the manifest, not on all of `packaging/**`; What this does and does not prove; The launch check, and why a timeout is not a failure; The first real run caught a genuine defect, before this manifest ever built in CI at all; What remains unverified until the fix runs for real.

## Two green pull requests can break main

It happened twice: a file at 507 lines after two PRs each under 500, and a shared test hitting an unmocked `SharedPreferences` channel.
`main` has no branch protection or ruleset (`gh api repos/Slim-m-org/slim-m/branches/main/protection` returns 404 on 2026-10-02), and a pull request is tested against the base it branched from, not the `main` it lands on.

| Option | Prevents it | Cost |
| --- | --- | --- |
| Merge queue | Yes: each entry is built on top of `main` plus the entries ahead of it, and only then merged | One extra full run per merge instead of per push; needs `merge_group` on each required workflow and a ruleset |
| Require "up to date with main" | Yes | Every other PR must update its branch and rerun the whole matrix after each merge, which is the stacked-PR rerun that made the queues deeper |
| Nightly main-health job | No, it detects it a day later | `red-streak-watchdog` already watches `e2e` and `main-builds`; `hygiene`, `client-ci` and `server-ci` on `main` have no equivalent |

The recommendation is the merge queue.
The repository half is done: `hygiene`, `client-ci`, `server-ci`, `schema-ci` and `licenses` run on `merge_group`, `.github/rulesets/main-merge-queue.json` is an importable ruleset, and `scripts/lib/test_merge_queue_ruleset_matches_the_workflows.py` keeps the two in step.
The ruleset requires only `hygiene` for now, because it is the one check every pull request reports; `client-ci` and `server-ci` are path-gated, so requiring them would leave an unrelated PR waiting forever for a check that never starts.
`hygiene` on the merged tree would have caught the 507-line file but not the `SharedPreferences` one.
The follow-up that closes that second gap is making `client-ci` and `server-ci` always report (a `changes` job and `if:` on the rest, so a skipped job counts as passed) and then adding their names to the ruleset; it was left out because it rewrites 12 jobs and cannot be tested without real runs.
The steps for the owner are in [CHANGING-CI.md](CHANGING-CI.md), section 5.

## Notes moved out of workflow headers

A `#` block in a workflow is capped at one line, so the longer reasons live here.

Details, in [ci-details.md](ci-details.md#notes-moved-out-of-workflow-headers): advisory-watchdog; audio-ci; red-streak-watchdog; client-windows-ci.
