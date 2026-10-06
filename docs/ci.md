# CI and the release pipeline

Why the workflows in `.github/workflows/` are shaped the way they are.

A YAML file has no doc-comment mechanism, so a `#` block at the top of a workflow is the only thing it can carry, and this repo caps a plain comment elsewhere at one line.
Anything that needs more room than that lives here, and the workflow keeps a short note pointing at the section.
Each section below is named for its workflow file.

## Workflows at a glance

| Workflow | Runs on | What it gates |
| --- | --- | --- |
| `server-ci` | changes under `crates/` or `.sqlx/`, `schema/openapi.yaml`, the Cargo files, `rust-toolchain.toml`, `docker/server.Dockerfile`, or its own workflow file, and every merge queue entry (`merge_group`, which ignores path filters) | fmt, clippy, sqlx cache check, tests, release build, binary size budget |
| `client-ci` | changes under `client/`, or to `schema/openapi.yaml`, `scripts/desktop-shell-smoke.sh`, `scripts/chrome-tests.sh` or its own workflow file; `update-golden-references` also by hand (workflow_dispatch), and every merge queue entry (`merge_group`, which ignores path filters) | dart analyze and format in one job, every package's tests plus the web build in another, the pure-logic tests listed in `client/chrome-tests.txt` compiled to JavaScript and run in Chrome in a third, so a typo reports in about a minute rather than fourteen; `update-golden-references` regenerates design_system's golden PNGs for a human to commit |
| `client-macos-ci` | a nightly schedule, and by hand | that the Dart and Swift compile against the macOS SDK. Compile-only, unsigned, and not a required check |
| `client-windows-ci` | pushes to `main` that touch `client/` or `packaging/windows/`, a nightly schedule, and by hand; not pull requests | that the native plugin graph links against the Windows SDK, and the Windows launcher's Go tests. Compile-only, and not a required check |
| `client-ios-ci` | changes under `client/packages/app/ios/`, `rtc/`, `platform/`, `data/`, the pubspec files, on pull requests and pushes to `main` | every `Runner` source file is registered in `project.pbxproj` (ubuntu, always), the iOS CallKit XCTest and extension-embeds-no-frameworks checks on macOS, and an unsigned Release-configuration device build when a native-relevant path changed |
| `schema-ci` | changes under `schema/`, `redocly.yaml` on pull requests; every push to `main` unconditionally, and every merge queue entry (`merge_group`, which ignores path filters) | redocly lint, the additive-only oasdiff gate against a PR's base on pull requests, and the same gate against the immediate parent commit on every push to `main` (required for a release; see below) |
| `audio-ci` | changes under `assets/audio/` | the seven notification sounds rebuild to the bytes that are committed, and the family is level with itself |
| `hygiene` | every pull request, and every push to `main`, and every merge queue entry (`merge_group`, which ignores path filters) | iOS purpose strings, the iOS broadcast extension is wired up, orientation is locked on phones only, no emoji in UI source, SPDX headers on Rust source, the file-size budget, the comment cap, and the `scripts/lib` unit tests, which include the two structural gates on `required_checks` |
| `advisory-watchdog` | a daily schedule, and by hand | nothing. It opens a deduplicated GitHub issue for a security advisory against a dependency and closes it once the tree is clean; the trigger `licenses` deliberately does not carry |
| `licenses` | changes to any dependency manifest or lockfile or to `deny.toml`; every push to `main`, and every merge queue entry (`merge_group`, which ignores path filters) | every Rust crate's and every pub package's license is in the one allowlist |
| `perf` | changes under `crates/`, `perf/`, the Cargo files; plus published releases | benches compile on PRs, benches run on a release |
| `compose-smoke` | changes to the self-host stack, a weekly schedule, and by hand | `docker compose up` on a fresh box produces a working deployment |
| `e2e` | every push to `main`; a nightly schedule; by hand; and pull requests only when they touch voice, calls, the canvas, the rtc/api packages, server auth/ws/hub/voice, migrations, the image, the schema or the harness (a superseded PR run is cancelled) | the whole product through two real headless browsers; advisory, not required |
| `push-relay-contract` | changes to the server's push path, and by hand | a server-generated envelope through the relay repo's real HTTP handler |
| `verify-release-checks` | called by `release`, twice, once per component | that this exact commit's own CI completed and succeeded before any publish job runs, on both the release-please and the by-hand tag paths |
| `copr-catch-up` | a completed `main-builds` run on `main` (any conclusion, cancelled included), a six-hourly schedule, and by hand | submits the client to COPR only when COPR's newest live build is older than `client/pubspec.yaml`, so a `main-builds` run cancelled by a merge storm no longer strands the Linux client; does nothing when COPR is current |
| `web-image` | called by `main-builds` (a client change) and by `release` (a server release) | the web client built into a signed multi-arch `ghcr.io/<owner>/slim-m-web` image, split out into its own file because `main-builds` is at the 500-line ceiling |
| `server-binaries` | called by `release` | the static musl server binaries per arch, uploaded as run artifacts for `server-release-assets`, split out into its own file because `release` is past the 500-line budget |
| `copr-publish` | called by `main-builds` and `copr-catch-up` | the Fedora COPR snapshot submission, split out into its own file once `main-builds` hit the 500-line ceiling; a failed submit is retried up to three times and then fails the job |
| `desktop-clients` | `client-v*` tag pushes, and by hand with a tag input | unsigned Windows and macOS tester archives, attached to the client's GitHub release, with the Windows launcher built and its Go tests run on the way, then the signed `update-manifest` job. The two desktop platforms `release` does not package |
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

## server-ci

Path-gated so a client-only change never triggers a server build.

`schema/openapi.yaml` is in the path filter even though it is not Rust.
`crates/slimm-server/tests/openapi_contract.rs` gates the schema against the router, so a schema-only edit that documents a path nothing serves, without touching `crates/`, must still run that test.
`crates/slimm-server/tests/response_contract/` goes further and validates real response bodies against the document, including refusals: one representative case per documented error status, since `Error` is the same object on every route.
Before that, every non-2xx returned before the schema was consulted, so an error body that had drifted from `Error` passed every gate here.

### The sqlx cache

`cargo sqlx prepare --workspace --check -- --all-targets`, against a database created and migrated in the same step.
It is the `cargo fmt --check` of `.sqlx/`: it re-derives every query's metadata from the real schema and fails if that differs from what is committed.

A *new or edited* query never needed this - sqlx keys each cache entry by a hash of the query text, so a query with no entry fails the offline build loudly on its own.
The gap is narrower and much quieter: a migration that changes a column's nullability or type **without touching any query text**.
The committed entries keep their old inferred types, the offline build compiles clean, and nothing re-derives them against the new schema.
A relaxed `NOT NULL` then ships a Rust type the database can no longer satisfy, and it surfaces as a runtime decode error against real data rather than as a red build.

`CLAUDE.md` is the realistic way in rather than a theoretical one: it says to regenerate `.sqlx/` after changing a `query!`, which a migration-only change is not.

### Unused dependencies

`cargo machete` runs beside clippy, because a dependency nobody imports is invisible to every other check here: the build is green, the tests pass and the binary works, so it accrues quietly until somebody goes looking.
It found one on the day it was added - `jiff`, declared in the workspace and never used by any crate, its only mention a doc comment in `http/search.rs` explaining why that call site had *not* used it - and removing it took ten crates out of the build: `jiff` and its four siblings, plus `bitflags`, three `defmt` crates and two `portable-atomic` ones.

It is source-text based, so it can be wrong, and a flag is a question rather than a verdict.
Anything it raises that is genuinely needed belongs in `[package.metadata.cargo-machete] ignored` with a reason, not deleted on its say-so.
The same audit run against the client's pubspecs is the cautionary half: three flags, three false positives, all of them native side-effect packages with no Dart API to import - `sqlite3_flutter_libs` bundling SQLite for drift, `media_kit_libs_video` whose own pubspec comment already says it is a no-op marker on Linux, and `firebase_core` behind `firebase_messaging`'s plugin registration.
There is no equivalent gate on the Dart side for that reason: it would be three false positives and nothing else.

`SQLX_OFFLINE: "true"` is set workflow-wide: the crate compiles against the committed `.sqlx` query cache and needs no database in CI.

The binary size budget step exists because the brief treats binary size as a first-class budget rather than something to notice after the fact.

## client-ci

Path-gated so a server-only or schema-only change never triggers the Flutter client build.

### Native build hooks are cached, and explain their own failures

Every job that runs `flutter build` or `flutter test` (here, in `client-macos-ci`, `client-windows-ci`, `client-ios-ci`, `desktop-clients`, `main-builds`, `release` and `flatpak-ci`) uses two composite actions.
`native-hooks-cache` caches `client/.dart_tool/hooks_runner/shared`, where sqlite3's build hook downloads the sqlite3mc binary (`shared/sqlite3/build/download-<hash>`).
The key is the runner OS and arch plus `hashFiles('client/pubspec.lock', 'client/pubspec.yaml')`: the lockfile pins the sqlite3 version and so the sqlite3mc release, and `pubspec.yaml` carries the `source: sqlite3mc` user define.
Only `shared` is cached because the per-hook directories beside it embed absolute pub-cache paths and are cheap to rebuild.
With `shared` restored and no network, the hook finishes and the tests pass, which is how this was checked locally.

Before this, nothing cached it, so an upstream hiccup failed an unrelated PR with only `Building assets for package:sqlite3 failed` (seen on #1501).
`native-hooks-diagnose` runs as an `if: failure()` step after the build.
Flutter does not keep a failed hook's stderr (`stderr.txt` is empty), so the action finds every hook directory with an `input.json` and no `output.json` and re-runs the command recorded in its `stdout.txt`, printing the real cause.

`media_kit_libs_linux` has the same shape: its CMake downloads mimalloc at configure time, before any hook, into `build/linux/x64/release/mimalloc-*.tar.gz`.
`native-hooks-cache` caches that archive on Linux, keyed on the lockfile (which pins the plugin and so the mimalloc release).
CMake skips the download when the file exists and only MD5-checks what it just downloaded, so a stale entry is not a risk as long as only a successful build saves the cache, which `actions/cache` guarantees.
A failed download leaves an empty archive and the log says only `Integrity check failed`, so `native-hooks-diagnose` reports a missing or empty archive as a failed download.
With both caches restored and no network, a full `flutter build linux --release` succeeds.

### Logic tests also run as JavaScript

The `test-chrome` job (`logic tests under dart2js (chrome)`) runs `scripts/chrome-tests.sh`, which feeds every file named in `client/chrome-tests.txt` to `flutter test --platform chrome`, one invocation per package.
dart2js evaluates integer shifts and 64-bit maths differently from the VM, so a bug can exist only in the web build: web ids once minted a wrong timestamp and the canvas grid key collided (#1540), both found only by running the suite under Chrome by hand.
The list holds 220 files (api, app, design_system, platform, rtc, voice_canvas), chosen by running every candidate that imports no `dart:io`, `dart:ffi`, drift or platform channel and keeping the ones that pass.
A file is opt-in: run `flutter test --platform chrome <file>` first and add it only if it passes.
Locally the whole list takes about nine minutes, but a CI runner took 20.6 minutes at the median (p90 21.1, max 21.8 over 38 runs), so the job runs as two legs (`logic tests under dart2js (chrome 1)` and `(chrome 2)`) and `CHROME_SHARD` hands each `flutter test --total-shards=2` its half of every package's files; each leg is about half of that plus setup.
The job has no `needs`, so it runs beside the test shards.
It is not in `verify-client-ci`'s `required_checks`.

### Where a pull request's time goes, measured 2026-10-02

Over the last 400 runs (2026-10-01 15:33 to 2026-10-02 01:25 UTC, 399 completed, jobs read with `gh run view --json jobs`):

| What | Median | p90 | Max |
| --- | --- | --- | --- |
| client-ci pull request run, wall clock, successful runs | 44.7 min | - | - |
| An app shard's test step | 11.4 min | 12.3 min | 14.9 min |
| App shard test-step medians, fastest to slowest shard | 10.7 min | - | 12.4 min |
| The `libmpv` apt step in a shard | 1.0 min | 4 to 17 min by shard | 24.9 min |
| `linux build deps` in `linux desktop compiles` | 1.3 min | 20.6 min | 26.7 min |
| The dart2js suite as one job | 20.6 min | 21.1 min | 21.8 min |
| A client-ci job's wait for a runner | 5 to 12 min | 70 to 85 min | - |

The test steps are balanced and fast.
The tail was apt: about 45 shard jobs were cancelled at the 25 minute limit while still inside the `libmpv` step, never inside a test.
So the eight-shard split stays, `libmpv2` (213 packages) replaces `libmpv-dev` (413) in the shards, the apt steps retry and carry their own step timeout, and the shard limit is 30 minutes, twice the slowest observed test step plus setup.
Runner-minutes per client PR, from the same data: the dart2js job 21, eight shards about 104, `other-packages` 6, `linux desktop compiles` 4 to 23, the rest under 6.

Cancellation is already per pull request: every workflow with a `pull_request` trigger groups on `github.ref` and cancels in progress, and none cancels on `main`.
`scripts/lib/test_pr_workflows_cancel_superseded_runs_but_main_never.py` pins both.
24 of 39 client-ci pull request runs in the window were cancelled by a newer push, which is that rule working.
Per-job `startedAt` minus run `createdAt` includes time spent waiting for `needs`, and a job cancelled while queued reports a `startedAt`, so a "wasted minutes" figure computed from it is inflated and is not quoted here.

### Runner labels are pinned

Every `runs-on` and matrix `runner` names `ubuntu-24.04` (or `ubuntu-24.04-arm`), never `ubuntu-latest`.
GitHub moves `ubuntu-latest` to Ubuntu 26 on 2026-10-19, which would change the glibc floor of the Linux tarball and rpm built on the runner and split the amd64 legs from the arm64 ones.
`scripts/lib/test_runners_are_pinned.py` refuses the label in any workflow.
Moving to a new image is a deliberate PR, dispatched against an existing tag first.
`windows-latest` and `macos-latest` are not pinned: no incident or notice covers them yet, and the iOS and macOS jobs depend on the Xcode that `macos-latest` carries.

### Goldens are not a separate job

Golden-file assertions (`matchesGoldenFile`) live inside each package's ordinary `flutter test` suite, not in a job of their own.
Golden PNGs are sensitive to the exact Flutter engine and Skia build and to font rendering, so goldens are generated and verified on the same `stable` channel on `ubuntu-24.04`.
If goldens start flaking across runs, pin an exact Flutter version in the workflow instead of floating on `stable`, and regenerate the goldens with `flutter test --update-goldens` on that same pinned version so both sides render identically.

design_system's two golden-bearing suites (`golden_matrix_test.dart`, `presence_desaturation_test.dart`) gate their pixel comparisons behind the compile-time flag `--dart-define=SLIMM_GOLDENS=true`, checked with `const bool.fromEnvironment('SLIMM_GOLDENS')`.
Nothing generated that flag's references on a contributor's own machine: doing so would diff against a Skia and font build CI does not use, which is a permanently red build in the making rather than a real gate.
The `test (every workspace package)` step in `client-ci`'s `test-web` job passes the flag itself, but only when `client/packages/design_system/test/goldens/` already holds PNGs; with the directory empty or absent it runs the same suites with the flag off, exactly as before this existed.
That makes the reference images, not a second workflow edit, the only thing standing between here and a real pixel gate: `update-golden-references` (workflow_dispatch only, so it never runs on a push or pull request) builds on the identical channel, Flutter version and runner as the test job, runs `flutter test --update-goldens --dart-define=SLIMM_GOLDENS=true` inside `design_system`, and uploads the resulting `goldens/` directory as a build artifact.
A human downloads that artifact and commits its PNGs into `client/packages/design_system/test/goldens/`; the very next `client-ci` run finds them and starts diffing, with no further edit to this workflow.
The same job is how a deliberate design change gets new references later: run it again, review the diff, commit the replacement PNGs.

### The iOS unit-test job, and why it is its own workflow

The CallKit synchronous-report invariant is a real termination risk, not a style rule.
iOS kills an app that takes a VoIP push without reporting a call before the handler returns, and repeat offences cost it VoIP push entirely.
That makes it worth a macOS runner of its own, because the ubuntu job runs Dart tests and cannot compile a line of Swift.
The wiring XCTest cannot see (no early exit before the report, the PushKit callback only calls the handler, `AppDelegate` constructs the registrar at launch, `voip` declared exactly then) is read from the Swift source by `scripts/lib/test_ios_voip_invariant.py` in the `hygiene` unittest suite.

The XCTest run is simulator only, so it needs no signing identity and no secrets: it compiles the Swift and runs XCTest, it does not produce a shippable build.
The signed device build stays in the release workflow.

### The registration and release-configuration checks, and why PR #292 needed both

Client 0.21.2 shipped a category on a private engine class from `ClipboardPasteBridge.m`, an undefined-symbol link error.
`ios unit tests` passed, because it links a Debug, simulator build; `build ipa` failed, because only a Release, device archive takes the same linking path the App Store review needs.
Separately, a new Swift file left out of `project.pbxproj`'s Sources build phase is skipped by `xcodebuild` with no error at all, so no test on either side can see it: not the native build (nothing failed) and not the Dart suite (it passes against a method channel that would have no handler).

Two checks close this, at very different costs.
`pbxproj-registration` is a grep over `project.pbxproj` with no Xcode involved, so it runs on `ubuntu-24.04` unconditionally, ahead of the macOS jobs.
The `ios-unit-tests` job gained a second build step, `flutter build ios --release --no-codesign`: a real, unsigned, device-target Release build, which is what takes the same linking path `build ipa` does.
That step is narrowed to the `changes` job's `native` path filter rather than "main is never trusted on a filter alone": unlike the XCTest job, a linking failure can only come from a native source file, `project.pbxproj`, or a dependency version, since Dart code takes no part in native linking.
Both checks are in `verify-client-ci`'s `required_checks`, since each can fail with the other green.

It lives in `client-ios-ci.yml` rather than beside the Dart job because it is the expensive one by an order of magnitude: 14 minutes against 5, measured across recent runs, which made `client-ci` a median of 11 minutes when the Dart half finishes in a third of that.
A GitHub workflow cannot path-filter one job, so the split is what lets it be gated on the paths that can actually change its answer: the iOS project, the plugins carrying CallKit and WebRTC, `data/` (its encrypted database compiles native sqlite code, and a change there once shipped an iOS launch failure with no iOS job run), and the dependency set, which is how a Dart-side change reaches an Xcode build.
A push to `main` uses the same filter, since it gates nothing except a release, and the release commit always matches it: release-please bumps `client/packages/app/pubspec.yaml`, which is in the filter.
CocoaPods is cached on the lockfiles, since rebuilding those pods is most of what the project-generation step spends its five minutes on.

`flutter build ios --simulator --no-codesign` runs first because xcodebuild needs the generated Flutter config and the plugin registrant to exist before the project will open, and only a Flutter build makes them.
`--no-codesign` keeps it to compiling, with no identity involved.

The simulator is chosen from what the runner actually has rather than by name.
A hardcoded `iPhone 16` broke the first time this ran, and it would break again silently every time GitHub rolls the image forward.

`schema/openapi.yaml` is in the path filter even though it is not Dart, for the same reason `server-ci` watches it: a client test reads it.
`packages/api`'s `schema_coverage_test.dart` fails when a route is documented with no `SlimmApi` call behind it, so a schema-only change can break this workflow while never triggering it.
That is not hypothetical - #675 documented `bulkDeleteMessages`, touched no `client/` file, and landed a red `api` package on main that no PR check had run.

## schema-ci

`oasdiff breaking` reports only changes that break existing clients: removed paths and fields, narrowed types, newly required properties, and similar.
Purely additive changes such as a new optional field or a new endpoint are not breaking and pass, which is what makes this gate additive-only by construction.

Two jobs run it, against two different bases, because one commit needs both.

`breaking-change-gate` runs on `pull_request` and diffs the PR's base against its head - the meaningful comparison for a reviewer, and the one that can catch a breaking change before it ever reaches `main`.
The PR's head commit is checked out explicitly rather than the default merge-ref checkout, so `HEAD:schema/openapi.yaml` is exactly the schema the PR proposes with no synthetic merge commit in between.
oasdiff also needs the base branch's schema content, but that checkout only fetched the PR head commit, so the workflow fetches just that one base commit, shallowly, by its exact SHA from the `pull_request` event payload, landing it in the local object database without cloning the base branch's history.
oasdiff then reads it straight out of git as `<base-sha>:schema/openapi.yaml`.

`breaking-change-gate-main` runs on every push to `main` instead, diffing `HEAD~1` against `HEAD`.
This is not redundant with the PR-time gate: `verify-release-checks.yml` (see below) polls check-runs on the exact commit a release verifies, a squash-merge mints a brand-new SHA that the PR-time gate's check-run was never attached to, and a release-please commit never touches `schema/**` at all - so `breaking-change-gate` structurally cannot ever appear on the commit a release actually checks, no matter how the required-checks list is written.
`breaking-change-gate-main` is what can: it is unconditioned on any path filter and runs on literally every push to `main`, trivially passing (an empty diff) on the overwhelming majority that never touch `schema/openapi.yaml` at all.
This relies on this repo's squash-merge-only convention (see "Contribution conventions" in `CLAUDE.md`): `HEAD~1` is exactly the one commit a merged PR added.
A direct multi-commit push to `main` bypassing that convention would only diff the last of them; not a concern under the convention this repo actually follows, and not worth the added complexity of walking further back for a case that should not happen.

### The one OpenAPI 3.0 `nullable` in the schema

`RegisterRequest.invite_code` in `schema/openapi.yaml` is written with the OpenAPI 3.0 `nullable` keyword, alone in a 3.1 document.
oasdiff cannot read a 3.1 `type: [x, "null"]` union and reports the conversion as the property losing nullability, which fails the additive-only gate, and redocly rejects carrying both forms at once.
It is a request property, so nothing is testable either way: the field is optional through `required` regardless, and the server takes an absent value and an explicit null identically.

## hygiene

### The shell, which nothing checked until 2026-09-11

22 workflow files, roughly 84 inline `run:` blocks and 17 shell scripts orchestrate every build, release and deploy this project has, and no linter looked at any of it.
That is the layer a mistake is most expensive in: a bad `${{ }}` expression, a `needs:` naming a job that does not exist, or an invalid key is a runtime failure on `main`, after the merge, rather than a red check on the pull request.

`actionlint` is the workflow half, pinned by image digest.
It also runs `shellcheck` over the inline `run:` blocks, so the two steps here cover the same language from both ends.
It found eight things when it was first run, all minor - unquoted `${PIPESTATUS[0]}`, unused `i` in four retry loops, two `ls | head` pipelines and one deliberately word-split variable - and all eight were fixed in the change that added it, so it lands green.
The word-split one is worth naming since it was in `release.yml`: `refs` became an array, which produces an argv identical to the old unquoted expansion for digest strings and cannot break on one containing a space.

`shellcheck` is the standalone-script half, run over every tracked `*.sh` plus every extensionless tracked file whose first line is a `sh` or `bash` shebang (the tarball's `packaging/linux/slim-m` launcher), and pinned by image digest for a reason worth recording: this gate failed on the very pull request that added it.
It was written against the runner's preinstalled shellcheck, and verified locally against the image tagged `stable`.
Those are different programs - the runner ships 0.10.0, `stable` is 0.11.0, and 0.11.0 no longer reports the `SC2015` that 0.10.0 does - so "clean locally" and "clean in CI" were answering about different versions.
A gate that disagrees with itself depending on where it runs is worse than no gate, so both linters here are pinned by digest.
The three `SC2015` sites it did find (`[[ -n "$PID" ]] && kill "$PID" || true` in two cleanup traps) are now plain `if` blocks, which reads better anyway, and every tracked script is clean under both versions.

### The e2e harness's own unit tests

`scripts/lib/test_*.py` covers the harness's scenario logic (the read-state and sync assertions, the settings assertions) against stubs, with no server and no browser.
`e2e.yml` runs the same discovery, but only on push to main and on path-matching PRs, and only as an advisory check; this is the unconditional `pull_request` gate on it, so a regression in the harness itself fails a PR rather than a nightly run nobody is watching.

### iOS purpose strings

App Store review rejects a binary whose linked SDKs reference a sensitive API without a purpose string, and it does it asynchronously.
altool uploads, the job goes green, and the rejection arrives by email some minutes later.
This gate turns that into a red PR instead.

### The iOS broadcast extension is wired up

Every piece of the screen-share broadcast extension (the Xcode target, its App Group, its Info.plist entries, its embedding in the app bundle) fails silently at runtime when wrong: the button does nothing, or the broadcast starts and sends no frames.
This step checks the identifiers agree with each other across `project.pbxproj` and both Info.plists rather than merely that each file exists, since that is exactly how this shipped broken once already.

### Orientation is locked on phones only

Phones are locked to portrait and tablets are free to rotate, on both platforms, and the two halves fail in opposite directions if either is quietly edited.
This step reads the iOS orientation arrays, the two Android `bools.xml` overrides, and the Kotlin code that applies the lock, and fails if any of the four no longer agrees with the others.

### No emoji in UI source

Emoji are user content (reactions), never interface chrome; chrome uses Lucide icons.
The gate fails on any emoji codepoint in client source.
It matches text sources only and passes `--binary-files=without-match`, so a compiled artifact that happens to contain those bytes cannot trip it.

### SPDX headers on Rust source

Every file under `crates/` needs an `SPDX-License-Identifier` header on its first line; this step fails and names the file otherwise.
the pre-trim CLAUDE.md's own contribution rule says "a CI gate checks the Rust ones," and `find crates -name '*.rs'` is that scope exactly, not a gap - widening it to the Dart, Swift and Kotlin sources that also lack headers is a separate, smaller decision nobody has made yet.

### The file-size budget

`scripts/check-file-budget.sh` enforces the rule in `CLAUDE.md`: 300 lines soft, 500 lines hard.
It warns at 300 and fails at 500, because 300 is the review budget rather than a limit and failing on it would fail the repository as it stands.
When this was written 64 files were over 300 and 14 were over 500.

The check runs over hand-authored source only, from `git ls-files`, so nothing untracked or ignored is counted: `.rs`, `.dart`, `.py`, `.sh`, `.swift`, `.kt`, `.kts`, `.js`, `.sql`, `.yml`, `.yaml`, `.toml`, `.cc`, `.h`, `.gradle`.
Generated Dart (`.g.dart`, `.freezed.dart`, the protobuf suffixes), the committed `.sqlx/` cache, the vendored `node_modules/` and `schema/openapi.yaml` are excluded, because their size is nobody's decision here.
The schema is the wire contract, already guarded by the router contract test and the additive-only breaking-change gate, and it had its own allowlist line that nearly every server PR edited, so any two of them conflicted.
Markdown is excluded too, deliberately: the budget is a code-review budget, and prose is not reviewed by the line.
Including it would put this file, `CLAUDE.md` and most of `docs/` over the hard limit on day one, which would make the gate noise rather than a gate.

The 14 files already past 500 are listed in `scripts/file-budget-allow.txt` with the line count they were listed at and a one-line reason.
That number is the point.
The three exhaustive-match files (`hub/event.rs`, `ws/authorization.rs`, `hub.rs`) keep their ceiling in steps of 50 so two PRs that each add one variant do not both rewrite the same number.
The gate treats it as that file's own ceiling, so a listed file may shrink and may not grow, and raising a number is a visible line in a diff somebody has to justify.
An entry whose file has dropped back under 500, or which no longer names a checked file, is an error rather than a silent no-op, so the list cannot rot the way a plain exemption list would.

Nothing in that list is a judgement that the file is acceptable.
The two worst are production code, not tests: `store/sessions.rs` at 815 lines carries tokens, refresh rotation, ws tickets and account deletion together, and `push.rs` at 600 carries envelope sealing, the relay client and fan-out triggering.
Splitting them is real work with real regression risk and does not belong in the change that introduces the gate.
`schema/openapi.yaml` and `release.yml` are the two that will most likely stay: one OpenAPI document split across `$ref` files would give `tests/openapi_contract.rs` two sources to reconcile, and the release workflow's ten publish jobs share release-please's outputs.

### The comment cap

`scripts/check-comment-cap.sh` enforces the other half of the same `CLAUDE.md` rule: a plain `//` or `#` comment never exceeds one line.
It ratchets rather than merely allows: a file may not gain a new run past its listed count, and the pre-existing ones are frozen at the count they were found at in `scripts/comment-cap-allow.txt`, the same shape as the file-size allowlist above.
Doc comments (`///`, `//!`, `/**`) are exempt everywhere.
Scope is Dart, Rust, Python, shell, YAML (inline workflow `run:` blocks included) and TOML.
Shell, YAML and TOML only have `#` comments, and a `#` block is also how such a file documents itself, so the leading block at the top of the file is a header and never counts as a run.
That covers the shebang, the SPDX line, a description and the blank lines between them, up to the first line of real content.
Any run after that point counts like it does in every other language, and `//` and `/* */` are not read as comments in these file types.

## licenses

Two jobs, one policy.
`deny.toml` holds the allowlist; cargo-deny reads it directly for the Rust tree and `scripts/check-dart-licenses.py` reads the same `[licenses]` table for the Dart tree.
One file rather than two, because the failure this gate exists to catch is a copyleft dependency arriving quietly in the Apache-2.0 client, and two policies that can drift is how that arrives.

It is not part of `hygiene` because both halves need a toolchain.
`hygiene` is the seconds-long grep job that runs on every push with nothing installed, and a cargo metadata resolve plus a `flutter pub get` would turn that into minutes.
So it is path-gated on the manifests, the lockfiles and the policy, plus every push to `main` whatever changed.

### What is allowed, and what is not

Every entry in `allow` is permissive and imposes no source-disclosure obligation on either the AGPL server or the Apache-2.0 client (see `LICENSING.md`).
Nothing is listed speculatively: the list is exactly what the two trees resolve to today, so a new license of any kind stops the gate and gets a human decision.

Three package-level exceptions, each named one package at a time rather than allowing the license outright:

- `slimm-server` is allowed `LicenseRef-PolyForm-Noncommercial-1.0.0`, since it is slim-m itself. Allowing that across the board would let an unrelated crate claim it unnoticed, which is the opposite of what this is for.
- `dbus` and `nm` are allowed `MPL-2.0`. MPL-2.0 is per-file copyleft: the obligation reaches modifications to those packages' own files and not the application that links them, so it is compatible with shipping an Apache-2.0 client. That is a decision rather than a default, which is why it is two named entries and not a line in `allow`; a new MPL dependency still stops the gate. Both are Linux desktop transitives reached through `connectivity_plus`.

Advisories and bans are deliberately not configured here, so this is `cargo deny check licenses` and not `check all`.
A CVE published upstream would turn every unrelated pull request red through no fault of its own, which is a different job wanting a different trigger; `docs/STRATEGY.md` names `cargo audit` and `osv-scanner` for it.
Advisories are checked daily by `advisory-watchdog` (cargo-deny `check advisories`, which gates nothing and opens an issue); `osv-scanner` is not wired.

`-A license-exception-not-encountered` is passed because the allow list is shared: `dbus` and `nm` are pub packages, so cargo-deny correctly reports never having seen them, and that is not a finding.
`unused-allowed-license = "allow"` in the config is there for the same reason in the other direction.

### The Dart half, and why it reads license text

pub has no cargo-deny, and a pub package declares no license anywhere in its pubspec; pub.dev derives what it displays from the package's `LICENSE` file.
So the script parses `client/pubspec.lock`, finds each hosted package in the pub cache, and classifies the license text itself.

That means the job has to run a real `flutter pub get --enforce-lockfile` first, and it means two failure modes are checked explicitly rather than skipped:

- A package the classifier cannot identify is an error, not a pass. A gate that shrugs at what it cannot read is not a gate, and the fix is to look at the file and either widen the classifier or record what it is.
- A package missing from the cache is an error naming the count, so an empty or partial cache fails loudly instead of the run going green having checked nothing.

One trap in the classifier, found by running it rather than by reading it: MPL-2.0's own text names the GPL, the LGPL and the AGPL, in the clause defining a Secondary License.
Matching the GNU family anywhere in the file therefore read `dbus` and `nm` as AGPL-3.0-only, which was a wrong label on a correct-enough refusal, and would have been a wrong label on a wrongly permissive answer just as easily.
The GNU family is matched against the first 600 characters only, where a real GPL text carries its title.

Today it reads 157 packages: 124 BSD-3-Clause, 24 MIT, 5 Apache-2.0, 2 BSD-2-Clause and the 2 MPL-2.0 above.

## perf

Path-gated to server and perf-scaffolding changes.
GitHub Actions does not support path filters on the `release` event, so the release-triggered job is not path-gated; it runs once per published release, except that it skips the `schema-v*` release the server config cuts alongside each server release.

`compile-gate` is a fast compile-only gate on every pull request: it proves the benchmarks still build without paying for a full measurement run on each push.

`benchmark` runs the real benchmarks once a release is published and uploads the criterion report as a workflow artifact, for hand-curation into a new `perf/baselines/<version>.json` (see `perf/README.md`).
It has no environment gate, and that is deliberate: it uploads only an intra-run workflow artifact, not a published release asset, so it is exempt for the same reason the release workflow's `server-binaries` build stage is.
Reviewer-gated Environments are applied at the true publish boundary (GHCR push, release assets, TestFlight), not to build-time artifacts.
No secrets are used.

## compose-smoke

The self-host stack is the product for most people, and nothing was checking that it boots.
Every other gate tests the server, the client or the schema in isolation; this one asks whether `docker compose up` on a fresh box actually produces a working deployment, which is the thing a self-hoster does first and the thing most likely to rot silently when a service is added.

It runs on changes to the stack itself and on a weekly schedule, because the failure mode it catches is usually an upstream image moving rather than a commit here.

### Building the image locally

The published image is only correct for `main`.
On a PR that changes the Dockerfile the whole point is to boot what that branch would produce, so the image is built locally under the tag `SLIMM_VERSION=smoke` resolves to, and compose uses it instead of pulling.

### Text chat on its own, which is the default

The base `docker-compose.yml` is a text-only deployment and that is a complete one, not a degraded one: the server treats an absent SFU as a normal configuration and answers 501 for every voice request.
So the first thing the smoke run does is bring up the stack with nothing but `SLIMM_API_DOMAIN` set, and assert the server becomes healthy and logs that voice is disabled.

That step exists for a specific regression rather than as a formality.
The shipped example used to pass `SLIMM_MAX_TOTAL_ATTACHMENT_BYTES: ${VAR:-}`, which is an empty string rather than an absent variable, and the server exited on boot with "cannot parse integer from empty string".
Nobody noticed because LiveKit's own `:?` requirement aborted compose earlier, so the example could not get far enough to reveal it.
A deployment that crash-loops must never be mistaken for one that simply has voice switched off, which is why the assertion is on the log line and not just on the container's health.

### Refusing to start without LiveKit credentials

`deploy/.env.example` ships `LIVEKIT_API_KEY` and `LIVEKIT_API_SECRET` empty on purpose.
Once the voice overlay is in play compose must refuse and name the missing one rather than starting an SFU anybody can mint tokens for, and that refusal is worth a test of its own because it is a security property, not a convenience.

Any of the three LiveKit names is a correct refusal: compose stops at the first variable it interpolates, and that order is not ours to fix.

### What the smoke run covers, and why only part of the stack

Caddy wants ports 80 and 443 and a real domain to get a certificate, and neither is available on a runner, so the smoke test covers the two services that carry the product: the server and the SFU.
Voice arrives through `docker-compose.voice.yml`, an overlay rather than a profile, because Compose refuses a project where a service outside a profile declares `depends_on` a service inside one - and Caddy legitimately depends on LiveKit when voice is on.
The run therefore covers both shapes in turn: text-only first, then the overlay enabled through `COMPOSE_FILE`.
The values written into `.env` are real-looking so the config renders; nothing there is reachable from outside the runner.

The server image ships no shell, so `/version` is asked for from the host through a throwaway container on the same network rather than by exec-ing into it.

`voice enabled` in the server log is the regression check for a real gap: the compose file ran an SFU for months without ever telling the server about it, so every voice request would have answered 501 on a stack that looked complete.

That line is still only the server's opinion of its own config, and says nothing about whether the SFU came up.
The first real deployment of this stack hit exactly that gap: the server reported voice enabled while LiveKit crashlooped on DNS behind it, and nothing in CI would have noticed.
So the SFU is checked separately, and because a crashloop looks like a start too, the job also confirms the container is still running a moment after the start line appears rather than trusting the one log line.

The last check is the end-to-end property that matters: a token signed the way the server signs one is a token this SFU honours.
A key and secret pair that reached only one of the two services would pass every check above and fail on the first real call.
The converse is checked too, so that check cannot be passing on an SFU that would accept anything.

That validation call is plain HTTP on purpose, and it is the only correct choice there: it is a container-to-container call on a private compose network, to the port LiveKit serves unencrypted by design.
TLS is Caddy's job one hop further out, and Caddy is not running on the runner because it has neither a domain nor a certificate to serve.

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

### red-streak-watchdog closes the "advisory and nobody is watching" gap this section already names

`e2e` has been red for a day, then red for two days a second time, each time with a release shipping over the top of it and nothing anywhere saying so; see PRs #379 and #550 for the two incidents.
Neither happened because `e2e` gates anything - it does not, on purpose, per this section above - they happened because nothing was watching a check that fails loudly in its own terms but reaches nobody.

`red-streak-watchdog.yml` runs on a daily schedule (plus `workflow_dispatch`; PR #688 cut it from hourly on purpose, to stop the watchdogs drowning the run history) and asks `scripts/check-workflow-red-streak.sh` a plain question of `e2e`'s own run history on `main`: how many completed runs in a row, most recent first, have failed, treating a cancelled run as neither a failure nor a recovery since it never actually ran the harness (see `e2e.yml`'s own "queued, not cancelled" concurrency comment).
A run whose only successful job is the `changes` filter built nothing, so it is skipped the same way: it neither resets the streak nor closes an open issue.
That shape is what a `main-builds` push whose paths matched no filter produces, and counting it as a recovery would close an issue with nothing proven.
Three in a row is the threshold - one is ordinary flake in a job driving a real browser and a real SFU, and firing on it would make this exactly the kind of check people learn to ignore, the same reasoning `e2e.yml`'s own header already gives for staying advisory in the first place.
Replayed against the actual 2026-08-09 incident's run history, three in a row was reached about 1h20m after the regression started, not the two days it took a person to notice.

**The signal is a GitHub issue, not this workflow's own colour.** A cancelled-while-pending run or a required check reading `cancelled` as failure are both already-documented ways a workflow's own status silently misses a problem (see "A release can succeed and still ship no store build" in CLAUDE.md); failing this workflow's job would only add a second thing nobody is watching. `scripts/check-workflow-red-streak.sh` opens an issue, labelled and deduplicated so a repeat run cannot open a second one, once the streak crosses the threshold, and closes it automatically the next time `e2e` succeeds on `main`. The label is created on first use rather than assumed to exist, since nothing else in this repository needs it.

Pulled into a script for the same reason `check-release-tag-lag.sh` was: `scripts/lib/test_check_workflow_red_streak.py` drives it against a fixture run list (`E2E_RUNS_JSON`) and a faked `gh` on PATH, so the threshold and the dedup/close logic are both tested without a real red workflow. One fixture replays the real 2026-08-09 history up to its third failure and asserts the script would have fired; a second is a genuinely mixed history (one failure among real successes) rather than an all-failure fixture, since an all-failure fixture proves nothing about where the threshold actually falls.

No concurrency group, the same reasoning the `release-tag-watchdog` section above gives for having none: an unconditional `cancel-in-progress: true` over a cron interval is what made that workflow fail three times within an hour of shipping (a run slower than its own 15-minute interval gets cancelled by the next one, and a cancelled run never asks the question), and this job is read-only and idempotent, so two of it overlapping costs nothing worth guarding against.

**This does not promote `e2e` to a required check.** `verify-release-checks.yml`'s required-check lists are untouched, and `e2e` runs on a pull request only when its path filter matches (see below). Whether to promote it is still the open question this section's own advisory-not-required paragraph leaves for the owner; this closes the separate problem of a red streak going unnoticed regardless of what the answer turns out to be.

It runs on pull requests as well, but only for the paths that can break what the harness drives (voice, calls, canvas, the rtc and api packages, server auth, ws, hub and voice code, migrations, `docker/`, the schema and the harness itself).
Owner decision 2026-09-29: at ~20 minutes it saturated the account's runners on every PR push and starved required checks, so a docs-only, bot-only or settings-UI change pays nothing and is covered by the push to `main` and the nightly run.
A superseded PR run is cancelled; runs on `main`, nightly and by hand still queue.
The red-streak watchdog reads only `main` runs, so it is unaffected.

That reverses the workflow's original position, and the reversal is worth recording because the original reasoning was good and still turned out to be incomplete.
The argument was that e2e is too slow and heavy for a pull request, and that the faster per-area workflows already gate one.
What that missed is that none of those workflows drives the product: when #653 moved the canvas into voice channels and the harness kept driving a text channel, fourteen scenarios were red on every commit for two days while every per-area check stayed green.
Both fixes then had to be merged unvalidated, because nothing ran e2e until after a merge.

It stays advisory rather than required even so.
Surfacing a break while it is cheap to fix is worth a slow check; blocking a merge on browser automation that can be flaky for unrelated reasons is a separate decision, and one to take only once real runs show it stable.

## push-relay-contract

The server and the relay agree on the push envelope's wire framing (field names, types, the platform and kind vocabulary, the payload size limit) but live in separate repos and languages, so nothing else here would notice one side changing it.
This is the only job that checks out both and runs a server-produced request through the relay's real HTTP handler.
See `crates/slimm-server/tests/push_relay_contract_fixture.rs` and slim-m-relay's `internal/api/push_relay_contract_test.go`.
The fixture it hands the relay holds `message` entries only, because the relay's test counts them against its own case table.
The same run also writes `push_relay_contract_kinds.generated.json` beside it, with one entry per other kind produced through the server's own path for it (`mention`, `call` on Android and on the iOS VoIP token, `call_end`, `security`), and asserts each entry's shape and sealed envelope in server CI.
The relay ignores that file until its own test adopts it, so a wire-name drift in those kinds fails on this side first.
The relay is checked out from this repository's own owner (`github.repository_owner`), so the two repos have to live under the same owner.

### No `token:` input on the relay checkout

The relay checkout deliberately passes no `token:` input.
An empty string is a provided value, not "unset", so it overrides checkout's own `default: ${{ github.token }}` and the step authenticates with a blank bearer instead of falling back to it, and GitHub responds 401 rather than serving the clone anonymously.
Leaving it unset lets the default apply, which is already sufficient to read a public repo.

### Three ways this job could go green having asserted nothing

Each of these is guarded explicitly, because all three fail silently.

A silently broken generation step, from a wrong env var name, a wrong path, or a future refactor of the fixture test that stops writing the file, must not fall through into the relay step quietly skipping while the job still goes green.
The workflow asserts the fixture file exists and is non-empty before using it.

A missing fixture at the relay step is a bug in this workflow, not a normal local-dev situation, so `SLIMM_PUSH_CONTRACT_FIXTURE_REQUIRED=1` makes the Go test fail loudly rather than take the `t.Skipf` it uses for an ordinary `go test ./...` run without a sibling slim-m checkout.

`go test -run` silently matching zero tests exits 0 with nothing asserted, which is the same failure shape as that skip.
Requiring the test's own `PASS` line means a typo'd pattern and a skip both fail the step.
`go test -v` prints the duration after the name (`--- PASS: X (0.00s)`), so anchoring the grep on the name alone would never match and the gate would fail every run regardless of the result.

## release

The full release and publish pipeline.

### How a release is cut

release-please maintains release PRs on push to `main`.
When a release PR is merged, that same push run cuts the GitHub Release plus tag and sets the per-package `release_created` outputs, which gate every downstream publish job.
A tag push does not start a run: since `RELEASE_PLEASE_TOKEN` is a PAT, the tag release-please creates raises a `push` event, and a tag trigger made every release publish twice (two TestFlight, Android and image runs on the same commit).
To re-publish, run `gh workflow run release.yml --ref <server-v*|client-v*>`.
The run reads the tag as `github.ref`, so the workflow and the checkout are both the tag's own, and a tag cut before this trigger existed has no `workflow_dispatch` to run; re-cut the tag on a newer commit instead.

The release-please job runs manifest mode twice, once per package, each against its own config and manifest file (`release-please-config.server.json` / `.release-please-manifest.server.json` for the server, the `.client.json` pair for the client), and only on main-branch pushes.
Splitting the manifest is what stops one package's release commit from conflicting the other's still-open standing PR: both used to read and write one shared `.release-please-manifest.json`, so merging either PR moved that file underneath the other, on every merge that did not also carry releasable commits for it. See PR #321 for the incident history.

The server config carries a second package rooted at the repo root, `.`, with component `schema`.
It exists for one reason: `schema/openapi.yaml`'s `info.version` has to track the server's own version, and `scripts/lib/test_openapi_version_matches_cargo.py` reds hygiene when it does not.
release-please resolves an `extra-files` path relative to the package directory, so a package rooted at `crates/slimm-server` cannot legally name a repo-root file - a parent-relative path is rejected with `illegal pathing characters in path`, and that rejection takes down every release-please run rather than just the one file, which is how PR #933 froze the standing release PR several merges behind main before #940 reverted it.
Declaring the key at the config's top level does not help either; the path still resolves against the package directory.
A package rooted at `.` can name the file, and the `linked-versions` plugin holds it to the server's version so a client-only release cannot drift `info.version` away from the server's Cargo version.
That package writes no changelog of its own (`skip-changelog`), but it does cut a `schema-v<version>` tag and GitHub release; see the next section for why.
Its one visible artifact is a repo-root `version.txt`, which `release-type: simple` maintains; nothing reads it, and it is auto-maintained so it cannot drift.
`scripts/lib/test_openapi_version_is_release_managed.py` pins each of those moving parts, since dropping any one silently returns us to hand-editing the release branch, which is how 0.46.0 and 0.47.0 shipped.

### The schema package cuts its own tag

The package used to set `skip-github-release`, so no `schema-v*` tag ever existed.
release-please reads a package's last version from the manifest but finds the commit for it from a release or the expected tag name, so with none it had no boundary and took the whole `commit-search-depth` window on every run.
Because the package is rooted at `.` it matches every commit in the repo, client-only merges included.
Any feature in that window made the schema package want a bump, and `linked-versions` dragged `crates/slimm-server` along with a `chore(server): Synchronize server versions` entry.
Merging that PR shipped a no-op server release, an image and a deploy, and the next run proposed another one (0.53.0, 0.67.0, then #1262).

The owner decided on 2026-09-29 to anchor the package instead of working around it: `skip-github-release` is dropped, so each server release now also creates `schema-v<version>`, and the second GitHub release per version is accepted.
The next run then has a boundary and only sees commits since the last release.

What was checked, not assumed:

- Branch and title do not change. The combined branch `release-please--branches--main` and title `chore: release main` follow from the package count and `separate-pull-requests`, and neither is touched. `skip-github-release` is not an input to the branch name. The open standing PR uses exactly that branch.
- `release.yml` only triggers its tag path on `server-v*` and `client-v*`, and reads outputs by the `crates/slimm-server--` and `client--` prefixes, so `schema-v*` starts no image, binary or desktop build. `desktop-clients.yml` is `client-v*` only.
- `perf.yml`'s `benchmark` job runs on any published release, so it skips `schema-v*` explicitly; otherwise the benchmarks would run twice per server version.
- `scripts/lib/test_openapi_version_is_release_managed.py` pins both the config and that guard.

Known limit: the manifest already reads `.` = 0.74.0 with no `schema-v0.74.0` tag, so the first release after this lands still walks the window once and anchors from then on.
Pushing `schema-v0.74.0` at the `server-v0.74.0` commit anchors it immediately; that is a new tag, not a moved one.
`release-tag-watchdog` also checks the schema tag against the `.` key of the server manifest, so a missing `schema-v<version>` is reported like a missing server or client tag.

That same `skip-github-release` history is why the server config carries `commit-search-depth`.
release-please bounds its walk back through main by the releases it can find, and a package that publishes no release gives it nothing to find: the run logs `looking for tagName: schema-v<version>`, then `could not find release`, and walks to the default depth of 500 merge commits every time.
That walk grew expensive enough to be refused outright on 2026-09-15, with GitHub answering the paged GraphQL query `Something went wrong while executing your query` at around 120 commits in - which failed the job, which left both standing release PRs frozen several merges behind main while every merge looked green.
A depth of 100 is far more history than this repo puts between two releases and bounds the query permanently.
The failure mode if it is ever too small is a commit missing from a changelog rather than a bad release, and it would show up as a release PR that does not mention a merge everyone can see on main.

### The release PR's own checks

Both `release-please-action` invocations take `token: ${{ secrets.RELEASE_PLEASE_TOKEN || secrets.GITHUB_TOKEN }}`, and which one is in play decides whether a release PR can ever go green.

A PR opened with `GITHUB_TOKEN` is authored by `app/github-actions`.
GitHub holds bot-triggered workflow runs at `action_required`, so `e2e`, `licenses` and `hygiene` never start on it, and the PR sits at `UNSTABLE` with only SonarCloud reporting, permanently.
It is not a failure and not a slow queue, and it looks identical from `gh pr checks` to the other reason a PR here shows few checks, which is a merge conflict.
Measured on 2026-08-18 over every `hygiene` run ever queued on a release-please branch: bot-triggered was held 13 of 13, owner-triggered ran 3 of 3, and the three that ran are the ones approved by hand.
The discriminator is `triggering_actor`, not the workflow, the branch or the event.

With `RELEASE_PLEASE_TOKEN` set to a fine-grained PAT, the PR is authored by the token's owner and its checks run like any other PR's.
The secret is set on this repository now, and the release PRs and the tags release-please cuts are authored by the owner.
The PAT needs `contents: read and write` and `pull requests: read and write` on this repository, and nothing else.
Set it with `gh secret set RELEASE_PLEASE_TOKEN` so the value never lands in a file or a shell history; rotating it is a re-run of that one command.

The fallback to `GITHUB_TOKEN` keeps releases working while the secret is absent, at the cost of that behaviour.
So an unset secret is a quiet degradation rather than a broken release, which is the right default for a self-hoster forking this repository, and the reason it is written as a fallback rather than required.
On a manual run on a tag both invocations are a no-op so downstream jobs can still resolve their outputs via `needs`.

Server and client are versioned and released independently, each with its own tag and its own set of jobs. Both are under PolyForm Noncommercial 1.0.0.

### Gating publish on the commit's own CI

Every publish job additionally requires `verify-server-ci` or `verify-client-ci` (`verify-release-checks.yml`, called twice) to have succeeded, on both trigger paths.
Before this existed, the tag path published unconditionally: `git tag server-v9.9.9 <sha> && git push --tags` built, signed and shipped an image with fmt, clippy, `cargo test --all`, the openapi-vs-router contract test, the license gate and the hygiene gates never having run on that ref, straight to a production deployment that auto-updates from the moving `latest` tag.

workflow_run cannot close this gap.
It fires only when a named workflow completes for the event that triggered it, and none of `server-ci`, `client-ci`, `client-ios-ci`, `hygiene` or `licenses` trigger on a tag push at all, by design, so that a ref that already ran CI on `main` does not run it again.
A tag push therefore raises no `workflow_run` event for any of them, which rules out the one mechanism that otherwise looks like the obvious fit.

The gate resolves the caller's `ref` (a tag on the release-please path, `github.sha` on the by-hand dispatch on a tag ref) to a commit SHA once, then polls `GET /repos/{owner}/{repo}/commits/{sha}/check-runs` for that SHA and requires each listed check-run name to show `status: completed` and `conclusion: success`, retrying for up to 180 minutes before failing on a timeout.
A check run is attached to the commit rather than to the event that produced it, so this answers both paths uniformly: the SHA a tag points at is normally already on `main` and already carries the check runs its original push or PR produced, so re-pushing a tag to the same SHA still finds them and still republishes, which is the documented re-publish capability above.
A required name **absent** from the response is treated the same as one that failed, never as a pass, so a commit that never went through CI at all (never pushed to `main`, never opened as a PR) times out and fails closed instead of silently succeeding on an empty result - unless something is still queued for that commit, in which case it keeps waiting past the grace period rather than giving up on a slow runner.
A `cancelled` check is pinned as a hard failure too, on purpose: see client-ios-ci.yml's own header on the concurrency group that used to cancel it on every push to `main`.

The polling loop itself is `scripts/verify-release-checks.sh`, not inlined in the workflow, so `scripts/lib/test_verify_release_checks.py` can drive it against a fake `gh`.
It shipped three separate incidents before anything tested it: a cancelled check read as success, the release-please path verified `github.sha` instead of the commit it actually released, and a tag was passed to an endpoint that only accepts a SHA.
All three are now regression tests, not just fixed code.

`verify-server-ci` requires `check` (server-ci), `hygiene`, `cargo dependency licenses` (licenses) and `breaking-change gate (additive-only, push to main)` (schema-ci).
`verify-client-ci` requires `analyze, format check`, `test and web build`, `linux desktop compiles` and `linux desktop shell smoke (Xvfb)` (all client-ci), `ios unit tests (callkit invariant)` and `ios sources are registered in project.pbxproj` (client-ios-ci), `hygiene`, `pub dependency licenses` (licenses) and the same schema-ci gate.

Every name in that list comes from `client-ci` or `client-ios-ci`, so both must run on the release commit itself, which is why neither path-excludes a release-please version bump the way `main-builds` does.
Excluding `client/CHANGELOG.md` and the two pubspecs once did exactly that: the checks were absent on the release commit, `verify-client-ci` timed out, and client 0.47.0 published its GitHub release and macOS/Windows builds but shipped nothing to COPR, TestFlight or Play.
`server-ci` never excluded its own version files, which is why server releases always delivered.
Do not re-add that exclusion to save a run on a version bump; it silently breaks client delivery.

Those names are matched by exact string against check-run names, and nothing in the workflow graph connects the string to the jobs it names.
`scripts/lib/test_release_required_checks_exist.py` is what closes that: it fails a pull request when a `required_checks` entry names no job, so a rename is caught there rather than at release time on `main`. Its sibling `test_release_required_checks_schema_gate.py` checks the other half - that the entry named can structurally reach a release commit at all.
The two Linux jobs joined the list on 2026-08-11: a release ships a Linux tarball, rpm and flatpak from every `client-v*` tag, and until then a client release could cut with the Linux desktop build red - the exact class both jobs' own doc comments describe main going red on, only at release time with nothing failing loudly.
Neither is path-filtered on `main` (both run on every push there), so the release commit always carries them; the iOS checks get the same guarantee from the pubspec bump matching their filter.
Those are exact check-run names (a job's `name:`, or its id when a job sets none), matched literally; renaming one of those jobs without updating the matching `required_checks` string silently reopens the gap this closes, since the renamed check is simply absent and the gate times out and fails rather than warns.

~~`schema-ci` is not required: `tests/openapi_contract.rs` already runs inside `server-ci`'s `cargo test --all`, and `schema-ci`'s own job is a redocly lint of the document's syntax, not part of what either release actually ships.~~
Wrong, and corrected once checked rather than assumed: `tests/openapi_contract.rs` gates the route surface - method and path - against the router, but never the shape of a response body, which is exactly what a breaking `oasdiff` change (a removed field, a narrowed type, a newly required property) reshapes.
Every already-installed client, on a self-host that auto-updates from `latest` or a phone on its own store-review schedule, is trusting that the wire only ever grows.
Nothing enforced that at the release gate before this: `breaking-change-gate`, the job that actually checks additive-only-ness, ran on pull requests alone, which protects a reviewed PR but not a release cut from whatever is on `main` regardless of how it got there - and branch protection requiring it on `main` is an owner-only repository setting, not something this gate can lean on.
`breaking-change-gate-main` (schema-ci) is what closes that: see its own section above for why the PR-time job could never be the one `required_checks` points at.

Every job that pushes to GHCR, signs, attaches release assets, or touches TestFlight runs under a reviewer-gated GitHub Environment and requests only the permissions it needs.
Secrets are referenced by name only and never invented; jobs stay inert, showing a visible warning and producing no fake artifact, until the corresponding secrets and packaging inputs exist.

The workflow-level `permissions` is a minimal default that individual jobs widen to exactly what they require.

### A queued run is not an in-flight run

`cancel-in-progress: false` protects a run that has already started; it says nothing about one still queued.
GitHub allows at most one pending run per concurrency group, and when a newer run is queued behind an already-pending one, the older pending run is cancelled outright - a different rule from `cancel-in-progress`, and one that flag cannot reach.
The group used to be keyed on `github.ref`, which is identical for every push to `main`, so two merges landing within one release run's runtime (roughly ten minutes end to end) put the second push's run in exactly that position.

This happened for real on 2026-08-06.
Run `31083287291` (the server 0.33.1 release commit) was in progress from 08:02:48.
Run `31083316052` (the client 0.32.1 release commit, pushed 26 seconds later) queued pending behind it.
A third, unrelated push (`c15e82f`, a canvas fix) landed at 08:13:40, while the server run was still going, and that new run replaced the pending client run in the group - `31083316052` shows `cancelled` with zero jobs ever started, confirmed against the real run history via `gh api repos/.../actions/runs/<id>/jobs`, which returns an empty job list for it.
Had the third push not arrived, main would have been left with a merged release PR, a bumped manifest, a changelog commit, no tag, and no store build, with nothing anywhere saying so - the same failure shape as "A release can succeed and still ship no store build" above, one layer deeper: there the required check itself was cancelled and read as a failure; here the *release run* is cancelled before any check can even run, and nothing polls for a run that never happened.
The only reason client 0.32.1 shipped that night is that the third push's own release-please invocation, running to completion at 08:13:40-08:14:36, found the already-merged-but-untagged client release PR and cut `client-v0.32.1` from it - confirmed by that tag pointing at the release commit's own SHA, not the third push's.

**The fix is keying the concurrency group on the commit, `release-${{ github.sha }}`, rather than the ref.**
Every push produces a distinct SHA, so two different commits' runs are never in the same group and neither can ever be left pending behind the other; each runs to completion independently, which is what actually guarantees a queued run is never silently dropped - not a narrower `cancel-in-progress` condition, which only ever governs a run already in progress.
This was checked against what serialization by ref was actually protecting, rather than assumed to be free: two release-please invocations running concurrently each touch only their own package's config and manifest file (see the manifest-split entry above), so a client run and a server run were already independent; and two *ordinary* pushes (no releasable commits) running their release-please refresh of a standing PR concurrently, rather than queued one after another, trades a rare git-ref race for never dropping a push's refresh entirely - a race there surfaces as one release-please job step failing visibly, which the standing-PR-conflict pattern documented above already establishes self-heals on the next push, where the previous behavior's silent full-run cancellation did not surface anywhere at all.
A job-level concurrency group scoped to just the `release-please` job, rather than the whole run, was considered and rejected: since every other job in this workflow transitively depends on `release-please`'s outputs, a cancelled-while-pending `release-please` job would starve the same downstream jobs a cancelled-while-pending *run* does today, reproducing the identical failure at job granularity rather than closing it.
`cancel-in-progress: false` is kept, now only relevant to the SHA appearing twice in the group (a re-triggered run against the same commit), which release-please's own tag creation cannot cause here: `release.yml` has no tag trigger, so the PAT-created tag does not re-trigger this workflow at that SHA (it once did, and published every release twice).

**`schema-ci.yml` had the identical hole, unrelated to this incident and found only by checking every other release-adjacent workflow for the same shape rather than assuming this was the only file with it.**
Its `breaking-change-gate-main` job is required by both `verify-server-ci` and `verify-client-ci` and runs on every push to `main`, but the workflow's `concurrency` block was `cancel-in-progress: true` unconditionally - the exact bug "A release can succeed and still ship no store build" above already fixed on `client-ci`, `client-ios-ci`, `hygiene` and `licenses`, left unapplied on the one workflow added after that fix landed.
It now carries the same `cancel-in-progress: ${{ github.ref != 'refs/heads/main' }}` condition those four already use.

**Superseded on 2026-08-11 by the stronger fix `release.yml` itself already used: all six required-check workflows (`hygiene`, `server-ci`, `client-ci`, `client-ios-ci`, `licenses`, `schema-ci`) now key their concurrency group per commit on `main`** (`group: <name>-${{ github.ref == 'refs/heads/main' && github.sha || github.ref }}`), keeping the ref-keyed group with cancellation on PR branches.
The conditional `cancel-in-progress` closed only the cancelled-while-running mechanism; a run still *queued* behind a pending one in the same ref-keyed group was still replaced outright, the separate rule the release.yml incident above proved `cancel-in-progress` cannot reach.
During a merge burst that left required checks silently missing on the middle commit, and `verify-release-checks` treats an absent required check the same as a failed one, so a release cut from that commit times out and fails 180 minutes later with nothing naming the cause.
Per-commit groups on `main` mean distinct pushes are never in one group, so no push's checks can be dropped by a newer push; the cost is concurrent runs during a burst, which these workflows tolerate by design (every job is read-only against the repo).
The other unconditionally-`true` workflows (`compose-smoke`, `audio-ci`, `push-relay-contract`, `perf`, `e2e`) were checked too and are not required checks in either `required_checks` string above, so a cancellation there cannot block a release the way `schema-ci`'s could; `main-builds.yml`'s own `cancel-in-progress: true` is unrelated to this release pipeline entirely and is documented as deliberate in its own section below.

**Proven versus reasoned, stated plainly.** The 2026-08-06 sequence above (run IDs, timestamps, an empty job list, the tag's own commit) is read from the real run history through `gh`, not inferred. That a SHA-keyed group can never produce a pending run is a property of the group key having no collisions across distinct pushes, which is git's own guarantee rather than something this repo can test against a real two-workflow-runs-racing GitHub instance; the git-ref-race trade for an ordinary push's release-please refresh is reasoned from how release-please's own standing-PR mechanism is documented to behave and from this repository's own recorded experience of it self-healing, not measured against a live race.
See PR #250 ("A release can succeed and still ship no store build") for the fuller incident record and the earlier variant of this bug.

### release-tag-watchdog closes the detection gap the fix alone leaves open

The SHA-keyed group stops a run from being silently cancelled, but nothing before this watched for the state that cancellation already produced once: a release-please manifest bumped to a new version, meaning its release PR merged, with no tag ever following it.
A push-triggered check cannot close this on its own, because the push that should have cut the tag is the same one that did not - there is no later event to hang a check on.
`release-tag-watchdog.yml` runs hourly instead (plus `workflow_dispatch`) and asks a plain question of git history: for each package, does the current manifest version have a matching `<component>-v<version>` tag, and if not, how long has the manifest read that version?
The workflow has no concurrency group on purpose: it shipped with `cancel-in-progress: true`, and a run slower than the cron interval was cancelled by the next one, three times in the first hour.
A cancelled run never asks the question, so the silent failure it exists to catch could pass underneath it; the job is read-only and idempotent, so overlap costs nothing.
`scripts/check-release-tag-lag.sh` does the check itself, pulled out so `scripts/lib/test_check_release_tag_lag.py` can drive it against a real temp git repo rather than the live one; a missing tag inside a 15-minute grace window is normal (the same run that merges a release PR usually tags it within its own run) and a missing tag past it is reported with `::error::`, naming the tag, the version, and how long it has been missing.

### The watchdog re-dispatches a release that verify timed out on

`verify-release-checks.sh` waits up to 180 minutes (10800 seconds; the job ceiling is 195).
The audit of 2026-09-29 measured the Linux queue p90 per day: 5 to 15 minutes on ordinary days, 45 minutes on 09-23 and 76 minutes on 09-25, with a single worst wait of 151 minutes.
Adding the 13-minute run of the slowest required check gives 164 minutes for the worst wait seen, so 180 passes every measured day, including the busiest, with margin.
The old 70 minutes failed that day, and client 0.84.0 to 0.86.0 lost their builds.
It fails closed as before: a failed check or an absent one with nothing running still ends the wait immediately.

A queue worse than that still leaves a release with no builds, so the `redispatch` job of `release-tag-watchdog.yml` recovers it.
`scripts/redispatch-stalled-release.py` takes each component's current manifest tag and dispatches `gh workflow run release.yml --ref <tag>` only when all of this holds:

- every release run for the tag's commit has completed, and at least one has a `verify-<component>-ci` job that failed, was cancelled or timed out, and none has one that succeeded;
- every name in that component's `required_checks` now shows `success` on the commit;
- the tag's commit is under 72 hours old;
- no `workflow_dispatch` run with the tag as its ref exists, whatever its outcome.

The last condition is the idempotency: GitHub's run history is the record, so a second hourly run, or a person who already dispatched by hand, finds it and does nothing.
A tag whose verify succeeded is never touched, even if a later build job failed; that is a different problem from a queue.
`scripts/lib/test_redispatch_stalled_release.py` covers the decision.

### server-image and server-image-merge

`server-image` builds one single-arch image per architecture on a native runner (amd64 on `ubuntu-24.04`, arm64 on `ubuntu-24.04-arm`), each pushed to GHCR by digest with an SBOM and max provenance.
There is no QEMU cross-compilation.
It needs no secrets beyond the automatic `GITHUB_TOKEN` (`packages: write` to push to GHCR), and no cosign key material is stored.
Every image job (here, `main-builds`' `server-image` and `web-image`) names its image `ghcr.io/<owner>/<image>`, with the owner taken from `GITHUB_REPOSITORY_OWNER` and lowercased, so the images follow the repository from `NC1107` to `Slim-m-org` rather than pushing to a namespace the moved repo's token cannot write.
`scripts/decide-latest-tag.sh` reads the owner back out of the image and lists its tags under `orgs/` first, then `users/`.

`server-image-merge` assembles the per-arch digests into one multi-arch manifest tag and cosign-signs it keylessly over OIDC.
It signs the manifest-list digest, which covers both arch images and every tag that resolves to it.

It also requires that *every* arch actually built, and that requirement has to be written out.
`server-image` is a `fail-fast: false` matrix, so one arch can fail while the other succeeds.
A job carrying any `if:` at all loses GitHub's implicit "every need succeeded" gate, and `server-image-merge`'s condition named only `verify-server-ci` - so a failed arch left it assembling a manifest out of whichever digests did arrive.
That publishes a **single-arch** image under the version tag, `sha-<commit>` and, when `decide-latest-tag.sh` allows it, `latest`, with the job green and nothing saying an architecture is missing.
Both halves of the fix are in `release.yml`: the condition names `needs.server-image.result` as well, and the digest download sets `if-no-files-found: error`.
`server-release-assets` had the same shape against `server-binaries` and carries the same fix, where the consequence was a GitHub Release with only one arch's binary attached.
`copr` was the third instance of it, found by an audit on 2026-09-21, in both `release.yml` and `main-builds.yml`: it consumes `linux-client`'s tarball with an `if:` that named only `verify-client-ci` and the `changes` outputs.
That one degraded quietly rather than publishing something wrong, because both COPR submission scripts run `set -uo pipefail` without `-e`, so a missing tarball became a `::warning::` and an exit 0 - a broken Linux client build showing green in a job nobody was watching.
`copr-catch-up.yml`'s `copr` job was a fourth, consuming the `tarball` job's artifact behind an `if:` that named only the `check` output; it carries the same fix.
All five pairs are pinned by name now in `scripts/lib/test_conditional_jobs_keep_their_needs_gate.py`, which also records why a blanket "every need appears in the `if:`" rule was rejected: nine jobs legitimately omit `release-please`, because the gate reaches them through `verify-server-ci` / `verify-client-ci`.

`latest` is the rolling tag deployments track for auto-updates, since Watchtower polls a mutable tag.
The version and sha tags stay alongside it, for pinning and for tracing an image back to its commit.

`server-image-merge` moves `latest` only when the version it is about to publish is the newest one GHCR has ever seen for this image, compared with `sort -V` against every semver-shaped tag the registry already lists (`scripts/decide-latest-tag.sh`).
Re-pushing an old `server-v*` tag (the documented re-publish capability above) still builds, signs and republishes that version's own tag, but `latest` is left pointing at whatever is genuinely newest, with a `::warning::` annotation naming what was skipped and why.
A tag listing GitHub cannot read (a rate limit, a permissions gap) fails the same way, closed: the step answers `false` and warns by name, rather than treating "could not tell" as "nothing published yet".
This protects only tags cut at a commit that already contains this script: GitHub runs the workflow and the scripts it calls from the pushed ref, so a `server-v*` tag pointing at an older commit (every one that exists through 0.18.5) still republishes unconditionally, moving `latest` exactly as before this existed.
Closing that needs something outside this file: a tag protection ruleset, or GHCR's own immutable-tag setting.
Without this, republishing a newer-than-nothing-else tag would silently roll every auto-updating deployment backwards to it.

### server-binaries and server-release-assets

`server-binaries` produces static musl binaries for direct download, built per arch into artifacts and aggregated by `server-release-assets`.
It is a reusable workflow (`server-binaries.yml`, one `server_version` input) called by the `server-binaries` job in `release`, which keeps that job's name and result for `server-release-assets` to gate on.
Each arch builds its own musl target natively on a native runner, with no `cross` and no QEMU, the same approach the container image uses.
It builds with `--locked`, the same as the container image and every other server build in this workflow, so the raw binary someone downloads is built from exactly what `Cargo.lock` pins.

`server-release-assets` attaches a GPG-signable `SHA256SUMS` plus the raw binaries to the server GitHub Release, under a reviewer-gated environment.
`GPG_PRIVATE_KEY` (ASCII-armored private key) and `GPG_PASSPHRASE` are optional: the attach still works without them and only the `.asc` is skipped.

### linux-client

The job publishes `slim-m-client-<version>-linux-amd64.tar.gz` on every client release, gated on nothing.
It is the Flutter bundle as built, plus the licence, `packaging/linux/README.md` and the `slim-m` launcher that names any missing shared library, under one top-level directory.
It resolves with `dart pub get --enforce-lockfile`, the same as the Android and iOS builds, so this download and the tarball the rpm and Flatpak jobs both build from are resolved from exactly what `pubspec.lock` pins.
That one artifact serves both readers: it is the download for a user whose distribution has no package, and it is the `Source0` the rpm spec fetches from the release.
Naming follows the server binaries in this same workflow (`slimm-server-<version>-linux-<arch>`), so one release page does not call the same machine `amd64` in one asset and `x86_64` in another.

Packaging then gates per format, not on both at once: `packaging/flatpak/top.npcserver.slimm.yaml` enables the Flatpak step and `packaging/rpm/slim-m-client.spec` enables the rpm step, independently.
An earlier version required both, which would have held a working rpm behind a flatpak manifest nobody had written.
Each missing input still warns by name, and the tarball ships either way.
The flatpak step also carries `continue-on-error: true`, unlike the rpm step: it has far fewer real releases behind it than the rpm, so a bad run must not be able to take the tarball or rpm down with it; see `packaging/flatpak/README.md`.
That guard let a real failure (`flatpak-builder` needs `eu-strip` from `elfutils` to strip debuginfo, and the step never installed it) hide across every release through `client-v0.61.0`, because a `continue-on-error` step's own `conclusion` reports `success` over the API regardless of what its logs say.
A `verify flatpak bundle was produced` step right after it stays non-blocking the same way, but fails by name and with an `::error::` annotation whenever `dist/*.flatpak` does not exist, so the next time the build breaks it is loud instead of silent.

The rpm is built inside a `fedora:latest` container rather than on the runner, because the spec is written against Fedora's macros and dependency generators and Ubuntu's `rpm` has neither.
It builds from the tarball staged moments earlier in the same job, not from the URL in `Source0`, since that release asset does not exist yet at that point in the run.
The `copr` job below is the one that goes through the published URL.
Both stamp the tag's version over the spec's `Version:` line, so a spec that is behind in git cannot mislabel a release.

The flatpak manifest is no longer a skeleton; see `packaging/flatpak/README.md` for what has actually been built and launched with it.

`GPG_PRIVATE_KEY` and `GPG_PASSPHRASE` are optional here too, for signing the checksums only.

The job installs `libsecret-1-dev` as a system build dependency.
`flutter_secure_storage` is a normal pub dependency of the platform package, used on iOS and Android (see `persistent_key_store.dart`), and pub has no per-target scoping that would keep its Linux plugin `flutter_secure_storage_linux` out of a Linux build's dependency graph.
That plugin's CMake config hard-requires `libsecret-1-dev` to even configure, regardless of whether the app ever calls into it on this platform.
Installing the one system package is simpler to maintain than splitting the platform package apart just to keep Linux out of that graph.

### copr

Submits the Fedora package to COPR at `nc1107/slim-m`, so `dnf copr enable` reaches a built and signed repository rather than a release page.
It runs in a `fedora:latest` container because `copr-cli`, `rpmbuild` and `spectool` are Fedora packages and installing them onto the Ubuntu runner is more work than using the distribution that ships them.

Two things make it inert rather than red.
It skips with a visible warning when `COPR_CONFIG` is unset, the same shape as the Android and iOS jobs, and it skips again when `packaging/rpm/slim-m-client.spec` does not exist, which is the same condition `linux-client` already gates its packaging steps on.
A submit that is attempted and fails is also only a warning: the `.rpm` is already attached to the release by then, so COPR being unreachable must not fail a release that has otherwise published everything.

`COPR_CONFIG` is the verbatim contents of `~/.config/copr`, the `[copr-cli]` block that <https://copr.fedorainfracloud.org/api/> generates.
It is a bearer credential for the whole COPR account, not just this project, and it expires: the token page states an expiry date and a build submitted after it fails with an authentication error rather than anything that names expiry.

The version reaches the spec through an `%app_version` macro appended to `~/.rpmmacros`, rather than a `--define` flag, because both `spectool` and `rpmbuild` read the macro file and the job needs the same value in both.
The `Version:` line is rewritten only when the spec hardcodes it; a spec that expands a macro there is left alone.

`spectool -g -R` downloads `Source0` into the SRPM before submitting.
That step is the whole reason this job exists in this shape: COPR builds in a mock buildroot with no network, so anything `Source0` points at has to already be inside the SRPM when it arrives.
It is also why the package repackages the release tarball instead of building from source, since a Flutter build resolves pub dependencies over the network and could never run there.

Operator-facing detail, including how to submit a build by hand, is in `packaging/fedora/README.md`.

### android-client

Builds the upload-signed apk and appbundle and attaches them to the client release.
It is inert until the signing secrets exist, and it verifies the signer is the upload key, since silently falling back to the debug keystore is the exact failure this job exists to close.

All three secrets must be present for the job to do real work:

- `ANDROID_UPLOAD_KEYSTORE_B64` - base64 of the upload keystore (`.jks`).
- `ANDROID_KEY_PROPERTIES` - the contents of `key.properties`.
- `ANDROID_GOOGLE_SERVICES_JSON` - the contents of `google-services.json`, which is gitignored; without it push is silently disabled.

`EXPECTED_SHA256` in the verify step is Play's registered upload certificate fingerprint.
It is public information, not a secret, and it is the only check that proves Play will accept the upload.
The apksigner output is captured to a file and echoed before matching, because the previous form assigned a grep pipeline and a miss aborted with no output at all.

Java is pinned to Temurin 21, the LTS the Android Gradle Plugin supports; local builds match.

Both the version and the tag are emitted by the resolve step: the tag names the release and the version feeds `--build-name`.
Emitting only the tag left `--build-name=` empty on every run before that was fixed.

### ios-testflight

Builds the signed ipa and uploads it to TestFlight, under a reviewer-gated environment.
It is intentionally inert until the signing and App Store Connect secrets exist, and warns and stops rather than faking an upload.

All eight secrets must be present for the job to do real work.
The list said six and named six until 2026-08-11, having never been updated when the broadcast extension gained a profile of its own:

- `APP_STORE_CONNECT_KEY_ID` - App Store Connect API key id.
- `APP_STORE_CONNECT_ISSUER_ID` - App Store Connect issuer id.
- `APP_STORE_CONNECT_PRIVATE_KEY` - the contents of the `.p8` API private key.
- `IOS_SIGNING_CERTIFICATE_P12` - base64 of the distribution certificate (`.p12`).
- `IOS_SIGNING_CERTIFICATE_PASSWORD` - the password for that `.p12`.
- `IOS_PROVISIONING_PROFILE` - base64 of the app's own `.mobileprovision` profile.
- `IOS_BROADCAST_PROVISIONING_PROFILE` - the same for the broadcast upload extension.
- `IOS_NSE_PROVISIONING_PROFILE` - the same for the notification service extension.

The app and both extensions are separately signed bundles, so each needs its own profile.
A missing one fails the export naming only that bundle id, which sends you looking at the wrong thing, so the gate checks all three before the build rather than at export time.

The signing identity goes into a throwaway keychain rather than the login one.
The runner is ephemeral, and a dedicated keychain keeps the private key out of any shared default that later steps touch.

`security set-key-partition-list` is mandatory: without it, `codesign` prompts for permission and hangs a headless run.

xcodebuild finds a provisioning profile by its UUID under `~/Library/MobileDevice/Provisioning Profiles`, so the file has to be named for the UUID embedded in its own signed plist.

The job prints the identities visible to codesign before building.
A signing failure downstream is otherwise reported only as "no valid code signing certificates were found", which says nothing about whether the import worked.

### Build numbers and build names, on both mobile jobs

`--enforce-lockfile` on `flutter pub get` so a release build resolves exactly what the committed `pubspec.lock` pins, rather than whatever is newest today.

`--build-number` comes from the GitHub run number, not from pubspec.
Both stores reject a build number that has already been used, and App Store Connect does it asynchronously: altool uploads happily, the job goes green, and the build is rejected minutes later by email.
That is how the iPhone build sat on build 4 through four client tags while CI looked fine every time.
A run number is monotonic and cannot be forgotten, so a reused build number stops being possible rather than being something to remember.

`--build-name` comes from the tag, not from pubspec.
The pubspec version is a local-build default and has sat at 0.1.0 across every release, so without this a tester cannot tell one build from another and every TestFlight build reads 0.1.0 whatever was tagged.

## client-macos-ci and client-windows-ci

Both are compile-only, both are deliberately not required checks, and both exist to catch a native break early rather than to prove the app works.
Because they gate nothing, neither runs per pull request: `client-macos-ci` is nightly and manual, and `client-windows-ci` runs on pushes to `main` plus nightly.
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
A check run is attached to the commit, not to the event, so polling the commit's check-runs answers both trigger paths the same way.
The names in `required_checks` are matched exactly, so a job renamed in `server-ci` or `client-ci` without the matching edit here blocks every release, which is the safe direction to fail.
The deadline covers queueing, not running: client 0.23.0 timed out at the old thirty-minute ceiling with `client-ios-ci` still queued, and that check passed minutes later.

## web-image

Builds `docker/web.Dockerfile` into `ghcr.io/<owner>/slim-m-web`: `flutter build web --release --base-href /app/` at the pinned Flutter version, behind the unprivileged nginx image (`docker/web-nginx.conf`), which runs as a non-root user on port 8080.
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

### Spotify client id

Linking a Spotify account needs a client id, which is the compile-time define `SLIMM_SPOTIFY_CLIENT_ID`.
The id is the repository variable of the same name, not a secret, and it is read as `vars.SLIMM_SPOTIFY_CLIENT_ID`.
A composite action cannot read `vars`, so the `linux-tarball` action takes it as the input `spotify_client_id` and its callers pass the variable in (PR #1531, [CHANGING-CI.md](CHANGING-CI.md)).
Every build a user installs passes it: the Android, iOS and Linux jobs in `release` and `main-builds`, the `linux-tarball` action (so `copr-catch-up` too), `desktop-clients`, and the web image through a build arg.
The test builds (`client-ci`, `client-ios-ci`, `client-macos-ci`, `client-windows-ci`, `flatpak-ci`) do not, because nothing runs or ships what they produce.
The release flatpak and rpm repackage the Linux bundle, so they carry whatever that build was given.
An empty value, which is what a fork pull request or a self-hoster without the variable gets, compiles fine and leaves the feature off.

nginx marks the entry points and `version.json` `no-cache`, `main.dart.js` immutable (it is only requested through its `?v=` URL) and everything else, `canvaskit/` included, revalidating on ETag because its URL carries no version, and answers at `/` and at `/app/`, because the live host's Traefik strips `/app` and a plain `docker run` does not.
`--pwa-strategy=none` keeps Flutter's service worker from serving an old bundle after a redeploy.

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

Version ordering is unchanged: `copr-publish` stamps the snapshot Release as `0.<run_number>` (this workflow's own counter), which sorts below the committed spec's `1`.
Because a catch-up only submits a Version COPR does not yet have, it cannot collide with a `main-builds` snapshot of the same Version, and a later tagged `-1` release still supersedes it.

## desktop-clients

The two desktop platforms `release` does not package: iOS goes through TestFlight, Android attaches an apk (no aab), and `linux-client` ships a tarball, an rpm and a flatpak, all from `release` itself.
This fills the gap with unsigned archives good enough to hand a tester, without touching `release`'s gated publish jobs.
The Windows zip also carries the `slim-m.exe` launcher built from `packaging/windows/launcher`, `install.cmd` and `install.ps1` for the first per-user install, and a `VERSION` file (decision 0041).

Unsigned is a stated trade rather than an oversight.
Windows has no signing certificate anywhere in this project, so SmartScreen shows "unrecognized app" and the tester clicks through.
The macOS app is ad-hoc signed by the build itself, so Gatekeeper quarantines a downloaded copy and a tester opens it with right-click Open, or strips the attribute with `xattr -d com.apple.quarantine`.

Both jobs declare `environment: release`, matching every asset-publishing job in `release`.
They are tag-triggered, so unlike `main-builds` they should sit behind a reviewer gate if one is ever added; `main-builds` documents its own opt-out for the opposite reason, that a continuous build must not block on review.

### The Windows build runs under pwsh, and the one release that shipped without it

Client 0.89.0 was published without its Windows zip and without `manifest.json`, so no desktop install on any platform could update to or from it until the release was backfilled.
The change that wired the Spotify client id into the build moved the Windows build step to `shell: bash`.
The job sets `CL` to a value that begins with a slash, Git Bash rewrites slash-leading environment values into Windows paths before handing them to a native program, and the first thing to notice was CMake: `No CMAKE_CXX_COMPILER could be found`, eleven seconds into `flutter build windows`.
The same tag built under pwsh on the same runner image, with nothing else changed, which is what the fix is.
The failed run took the manifest job with it, because `manifest` needs both desktop builds and a failed need skips it without a word.

Two things made it expensive.
This workflow runs on a tag and nowhere else, so the pull request that broke it could not have failed: the first run of a change here is the release.
That still holds.
And nothing compared a published release against the assets it should have, so the release page looked finished; `release-asset-watchdog` does that now.

`scripts/lib/test_windows_builds_do_not_run_under_bash.py` refuses `flutter build` under `shell: bash` in any Windows job.
That closes this exact door and no other.
Before merging a change to this file, dispatch it from the branch against the newest existing tag (`gh workflow run desktop-clients.yml --ref <branch> -f tag=client-vX.Y.Z`): it rebuilds and re-attaches the same assets with `--clobber`, which is harmless, and it is the only way the change runs before a release depends on it.

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
A tagged release still supersedes all of this: it wins over any COPR snapshot of the same version (see the versioning section below), and it alone attaches signed assets to the GitHub release.

### What triggers it, and the one filter step that replaces two workflows

A single `on.push.paths` list cannot tell a client-only merge from a server-only one, so the trigger is deliberately wide (`client/**`, `crates/**` or `packaging/**`, minus a release commit's own `client/CHANGELOG.md` and `client/pubspec.yaml`, plus the root server files and every local action and reusable workflow the file calls) and a `changes` job built on `dorny/paths-filter` narrows that into the three booleans (`client`, `server`, `packaging`) every downstream job gates on.
The brief allowed splitting this into two workflows with their own top-level `paths` instead; one workflow with one filter step was chosen because it keeps the concurrency group, the header, and this section in one place, and because the filter step is one checkout rather than two.

The filter's own patterns are include-only, and that is load-bearing rather than tidy.
`dorny/paths-filter` defaults to predicate-quantifier `some`, which ORs the patterns, so a negated entry like `!client/CHANGELOG.md` is true of nearly every file in the repository and makes the whole filter match unconditionally.
That is exactly what it did: the Android, iOS and Linux client jobs ran on every server-only merge, uploading a TestFlight build with no client change in it.
The version-bump exclusion belongs in `on.push.paths` above, where GitHub's own path semantics apply negation correctly, and it lives there now.

`packaging` used to not exist, and every job below gated on `client`/`server` alone even though `on.push.paths` already listed `packaging/**`.
The trigger fired on a packaging-only commit, and then every downstream job's own `if:` read `client`/`server` as both false and skipped, so the run did nothing at all; confirmed directly against the real run for the commit that merged #964, which touched only `packaging/flatpak/top.npcserver.slimm.yaml`.
`linux-client` (the rpm build) and `copr` now also gate on `packaging`, so a packaging-only change reaches them; `android-client` and `ios-testflight` deliberately do not, since a packaging change has nothing to do with either.

The two client exclusions are load-bearing.
A release-please release commit for the client touches exactly `.release-please-manifest.client.json`, `client/CHANGELOG.md` and `client/pubspec.yaml` (verified against the actual `chore(main): release client 0.16.0` commit, back when the manifest was still the single shared file; the split manifest changed only which root-level file name that first one is).
Without the exclusions, that commit would also match `client/**`, and this workflow would rebuild and re-upload the exact commit `release.yml` just shipped to TestFlight and Play, under the same version, racing a second altool upload against the first.
No equivalent exclusion exists for the server side: a server release-please commit touches `crates/slimm-server/Cargo.toml` and `crates/slimm-server/CHANGELOG.md`, both under `crates/**`, so it still re-triggers `server-image` here.
That is accepted rather than worked around: excluding `Cargo.toml` from the trigger would also hide a real dependency-bump PR that happens to touch only that file, and there is no path-only way to tell the two apart.
The redundant build pushes the same `latest` the release itself would have pushed moments earlier for the same commit, so nothing wrong reaches production; it is simply a build that did not need to happen.

The trigger must also name everything the workflow calls.
Commit f453f678 fixed `.github/actions/linux-tarball` and matched no path, so the run it started skipped every job and finished green with nothing built.
`.github/actions/**` now triggers the run and feeds the `client` filter, and `copr-publish.yml` feeds `packaging`.
`scripts/lib/test_main_builds_triggers_on_everything_it_uses.py` fails when a `uses: ./.github/...` target is missing from the trigger or the filter, or when a trigger path reaches no filter and is not on its short allowlist.
A change to `main-builds.yml` itself still triggers a run that builds nothing; that is on the allowlist on purpose.

### What each side does

The client side reuses `release.yml`'s `ios-testflight`, `android-client` and `linux-client` steps verbatim where the two paths overlap: the throwaway keychain and `set-key-partition-list` for iOS, the upload-key signer verification for Android, the Fedora container for the rpm build.
It differs because there is no tagged release to publish against: `softprops/action-gh-release` has nothing to attach to on an untagged push, so the Android apk and aab go up as `actions/upload-artifact` run artifacts instead (there is no Android device to test the push path here, and the Play upload stays manual regardless, so an artifact is all this path is for).
The Linux side goes further than an artifact: it lands on the owner's actual Fedora machine, through COPR, covered in its own section below.
And the version name passed to `--build-name` is read directly out of `client/pubspec.yaml` (the file release-please itself writes, and the exact value this workflow's own trigger excludes from re-triggering it) rather than out of a release-please output or a tag, since neither exists here; it therefore repeats across every continuous build until the next real release moves it, which is fine, because uniqueness is per version-and-build, not per version alone.
`--build-number` still comes from `github.run_number`, exactly as `release.yml` uses its own, for the same reason: both stores reject a reused build number for a version.
Worth naming rather than assuming away: `release.yml` and `main-builds.yml` are two different workflow files, so each has its own independent `run_number` counter, and nothing here proves those two counters can never land on the same integer while a version briefly overlaps between a continuous build and the release that follows it.
No such collision has been observed, and `release.yml` runs on every push to `main` regardless of path while this workflow only runs on a subset of those pushes, which keeps its counter behind; if that ever stops holding, the fix is to derive the build number from something workflow-independent, such as a count of commits.

The server side pushes one native `linux/amd64` image to GHCR, tagged `sha-<commit>`, `main` and `latest`, with no arm64 build, no digest-then-merge manifest assembly and no cosign signing.
amd64 only because nothing consumes an arm64 image from this path: the owner's live instance (the pre-trim `CLAUDE.md`'s "Running deployment" section) is an amd64 Ubuntu Docker host, and a released version still gets the full signed multi-arch manifest `release.yml` builds.
Moving `latest` here is continuous deployment in the plain sense of the term: Watchtower on the live instance polls that tag, so a server merge reaches production within one build with nobody deploying it by hand, and a bad merge reaches it exactly as fast.
That is the trade the owner asked for explicitly, not a gap: fast iteration on the one host that matters to him, at the cost of no gate between a merge and production.

### Fedora, COPR, and the two problems a snapshot build has that a release does not

`packaging/rpm/slim-m-client.spec`'s `Source0` points at a GitHub *release* asset (`.../releases/download/client-v%{version}/slim-m-client-%{version}-linux-amd64.tar.gz`), and the release path's `copr` job fetches it with `spectool -g -R` because COPR's mock buildroot has no network and needs the tarball inside the SRPM before it submits.
An untagged main push has no such release, so `spectool` would 404 on every single continuous build.
The fix is not to create a release to satisfy it: `linux-client` already builds the identical tarball for its own rpm, uploads it as the `slim-m-client-tarball` artifact, and the `copr` job downloads that artifact and copies it into `~/rpmbuild/SOURCES/` under the exact filename `Source0` names, then calls `rpmbuild -bs` directly with no `spectool` step at all.
The release path's own `spectool` call is untouched; this is a second, parallel way of populating `SOURCES/`, not a change to the first.

The spec is committed at `Version: 0.4.0` / `Release: 1%{?dist}`, and the release job already rewrites `Version` to the tag's version on its own copy of the spec, never on the one in git.
A continuous build does the same version rewrite (to the client's current tracked version, read out of `client/pubspec.yaml`, the same value the mobile builds use), but it also has to rewrite `Release`, or every snapshot of one version would collide with the committed `1%{?dist}` and with each other.
It is set to `0.${{ github.run_number }}%{?dist}`.
RPM's version comparison splits `Release` into alphanumeric segments and compares them one at a time, so `0.<n>` and `1` compare on their first segment, `0` against `1`, and `0` always loses.
That means every snapshot of a given version sorts below the real tagged release of that same version, however high its own run number climbs, so cutting an actual release always supersedes whatever snapshots came before it on `dnf upgrade`, while snapshots still sort in increasing order among themselves because `run_number` only grows.
Neither the committed spec's `Release:` line nor the release path's own behaviour is touched; both rewrites happen only on the build-time copy under `~/rpmbuild/SPECS/`.

### Secrets, gating, and the environments it deliberately does not use

Every job that needs a secret checks for it first and warns rather than fails when it is absent, the identical shape `release.yml` uses for its Android, iOS and COPR jobs: a fork or a repo missing a credential gets a visible warning and a skipped step, never a red required check.
`release.yml`'s equivalent jobs declare `environment: release` or `environment: testflight`; this workflow's jobs deliberately do not.
Checked directly against the repository (`gh secret list`, `gh api repos/.../environments`): every secret these jobs read is a repository-level secret, not an environment-level one, and both environments currently carry no protection rules, so omitting the environment name changes nothing about what a job can read today.
It is still the right default for this workflow rather than an oversight: an owner open item already on record is adding reviewer protection to those two environments for real releases, and if that lands later, a job that names the same environment here would suddenly require a manual approval on every ordinary merge, which defeats the entire point of a fast, unattended path.

### Concurrency, and why it is the opposite of `release.yml`

`release.yml` sets `cancel-in-progress: false`, because a half-published release is worse than a queued one.
This workflow sets it `true`, on the reasoning that a continuous build carries no such asymmetry: a newer commit's build supersedes an older one's, so cancelling the older run in favour of the newer one loses nothing worth keeping.

**That reasoning has one hole, and it cost a day's worth of undeployed server fixes on 2026-09-10.**
A newer run only supersedes an older one for the sides its own `changes` filter turns on.
If the cancelled run was the only one whose filter said `server: true`, and the push that cancelled it touched `client/**` alone, then `server-image` is cancelled in the first run and *skipped* in the second, and no image is ever published.
Nothing reports this: both runs end green, because a skipped job is a successful run.

Measured, not reasoned: `fad3339d` (a server fix to the avatar change event) had `server-image` cancelled by the next merge, and every main-builds run after it that day - `483d5fa`, `be39c5e`, `57f2e5e`, `92dd49a`, `cf109c1`, `baf2b58` - reported `server-image: skipped`.
GHCR's `latest` still pointed at `sha-f6dab94a` from 03:15Z, and the live instance was running a 16-hour-old container with two merged server changes missing from it.
Re-running the cancelled job alone does not recover it either: `server-image` needs `changes`, and in a cancelled run that dependency has no output, so the rerun skips as well.

`workflow_dispatch` is the manual recovery path: three booleans, one per side, ORed into the filter's own outputs so a manual run builds exactly what is asked for and a push behaves exactly as before.

**The structural fix is the `undeployed` step**, which stops deciding the server side from the push's own diff.
`scripts/server-image-needed.sh` finds the newest `main-builds` run whose `server-image` job really succeeded, and reports `server: true` when anything under `crates/**` has moved since that commit.
The question becomes "has the server changed since the image that is actually out there", which is the question this job exists to answer, so a cancelled build is picked up by the next push of any kind rather than lost.
Checked against the incident above: `git diff 92dd49a2..ab598657 -- crates/` names `crates/slimm-server/src/lib.rs`, so the missed identity-log image would have been rebuilt by the very next client-only merge; the same diff from `6d437bd1`, which `latest` did hold, is empty, so a settled server side still costs no build.

It reports `server: true` and never `server: false` - the paths filter beside it owns that answer.
Every way of failing to resolve a base commit (a short history, a GitHub hiccup, an unreachable SHA) prints a line and stays quiet, leaving the filter as the only voice.
That is the old behaviour, and it is the safe direction: an extra image costs minutes of runner time, a missed one costs a deploy nobody notices.
`scripts/lib/test_server_image_base.py` pins the decision itself, including the cancelled-then-skipped shape this was built for, and that malformed API output degrades rather than fails.

`client` and `packaging` still decide from the push diff alone and keep the same hole.
That is deliberate for now: a missed TestFlight or COPR build is visible to whoever goes looking for it on their phone or in `dnf upgrade`, where a missed server image is invisible until somebody notices a fix is not live.

## flatpak-ci

The gap this closes: before it existed, nothing in CI ever built the flatpak except `release.yml`'s `linux-client` job, which only runs at `client-v*` tag time (or when release-please has just cut a client release).
`desktop-clients.yml` is tag-only too, for Windows and macOS.
`main-builds.yml` lists `packaging/**` in its own trigger, but never builds the flatpak at all, on any push; it only builds the rpm and the tarball, and even that was silently skipped for a packaging-only commit until the `changes`-job fix described above.
So a broken flatpak manifest reached `main` and shipped to whoever installed client 0.60.x through Flatpak before anything caught it: PR #964 fixed the underlying defect (`media_kit_video`'s Linux plugin has a hard `NEEDED` entry on `libmpv.so.2`, which the freedesktop 25.08 runtime does not carry, so the app failed to launch at all), and PR #964 itself passed with only SonarCloud and hygiene as checks.

### Why a full build, not a manifest lint

A schema/lint check on the YAML would not have caught #964.
`flatpak-builder` builds a manifest that omits a runtime library without complaint; the failure only exists at `dlopen` time, when the installed app actually starts and the dynamic loader cannot resolve `libmpv.so.2`.
`packaging/flatpak/README.md`'s own account of finding this defect is explicit that it was found "by actually building both versions and launching each, rather than reasoning from the plugin's ELF headers alone."
A lint is cheap but would have reported this manifest as fine, which is worse than the two-checks status quo it replaces: a green check that cannot see the actual failure mode invites more trust than no check at all.

### Why gated narrowly on the manifest, not on all of `packaging/**`

The build compiles mpv, libplacebo, libass and the `libayatana-appindicator` stack from source; per `packaging/flatpak/README.md` this has taken multiple real passes on the author's own machine and is not a build to run on every PR.
`packaging/**` also covers the rpm spec, the Linux desktop file and the icon set, none of which touch the flatpak sandbox at all, so a build gated on that whole tree would run far more often than the manifest actually changes.
Triggering only on `packaging/flatpak/top.npcserver.slimm.yaml` and `packaging/flatpak/shared-modules/**` (the vendored build inputs the manifest reads directly) keeps the expensive path rare without weakening it: those are exactly the files whose breakage this workflow exists to catch, and per the manifest's own README they have changed only a handful of times since the manifest was introduced.

### What this does and does not prove

It builds on `ubuntu-24.04`, the same runner `release.yml`'s `linux-client` job uses, and installs the same `linux-build-deps` composite action, so it links against the same host packages, notably `libayatana-appindicator3-dev`.
`packaging/flatpak/README.md` documents a real host-dependent link: `tray_manager`'s CMake picks `ayatana-appindicator3-0.1` or the older `appindicator3-0.1` from whichever the build host's pkg-config offers, and a Fedora desktop build links a different soname than Ubuntu CI does.
Building on the same Ubuntu runner CI already uses for the raw Linux build means this check cannot diverge that way itself; it does not and cannot prove anything about a contributor's own machine, since it never builds on one.

It also does not catch a client-side change that adds a new native Linux dependency without touching this manifest in the same PR.
The regression class #964 fixed was really introduced whenever `media_kit_video` was wired into the client, not when the manifest was edited to catch up; a future plugin addition with the identical shape would not trigger this workflow unless the same PR also touches the flatpak manifest.
Closing that fully would mean cross-checking the flatpak manifest's declared modules against `linux-build-deps`' apt package list on every client change, which is out of scope here and left as a known gap.

### The launch check, and why a timeout is not a failure

After installing the built bundle, the job runs `flatpak run` for 20 seconds under `xvfb-run` and a private D-Bus session (`dbus-run-session`, which ships in the `dbus-daemon` package on Ubuntu 24.04/noble, not `dbus-bin`; checked directly against `packages.ubuntu.com`'s content search for that suite and architecture rather than assumed).
The check asserts positively rather than only on a bad substring, because a grep-for-the-known-error-else-pass shape is exactly the "green check that verifies nothing" `#967` fixed elsewhere in this pipeline: it would pass just as readily on an empty log, or on `flatpak run` never actually starting the sandbox, as it would on a clean run.
So the step fails on any of: the captured log being empty (the launch never happened at all); a line indicating the sandbox itself failed to start or the app could not be found (`bwrap:`, a permission or namespace error, "not installed", "no such ref" - proves nothing about the bundle's own libraries either way); the literal dynamic-linker error `#964` reproduced (`error while loading shared libraries`, `cannot open shared object file`); or any other nonzero exit code that is not `timeout`'s own `124`.
`124` is treated as the expected shape, not a failure: `packaging/flatpak/README.md` records that this app has never been confirmed to paint a window in any environment tried so far, only that a fixed manifest gets past plugin loading and into the engine's own run loop, which does not exit on its own, so getting killed by the 20-second timeout is what success looks like here.

### The first real run caught a genuine defect, before this manifest ever built in CI at all

This workflow's very first run failed the `build flatpak` step: `libayatana-indicator`'s CMake configure could not find `libayatana-ido3-0.4` via `pkg-config`, even though `ayatana-ido` (which provides it) builds directly before it in the module order.
The real cause, read from that run's own log rather than reasoned from the manifest text: `ayatana-ido` installed to `/app/lib64/pkgconfig`, not `/app/lib/pkgconfig`, because CMake's `GNUInstallDirs` module defaults `CMAKE_INSTALL_LIBDIR` to `lib64` on any 64-bit Linux system lacking `/etc/debian_version`, which the `org.freedesktop.Sdk//25.08` build sandbox is.
`flatpak-builder` has shipped an unconditional `-DCMAKE_INSTALL_LIBDIR:PATH='lib'` default for `cmake`/`cmake-ninja` modules since July 2024 specifically to paper over this, but Ubuntu 24.04's apt package is `flatpak-builder 1.4.2-1build2` (read from the failing run's own `apt-get install` log), which predates that default: checked directly against that tag's own `src/builder-module.c`, it only sets `CMAKE_INSTALL_LIBDIR` when a module's manifest sets `build-options.libdir` explicitly.
`org.flatpak.Builder`, the newer, Flathub-published tool this manifest's local verification passes use, already carries the safe default, which is why this never surfaced before this workflow existed: nothing had ever built this manifest with the specific `flatpak-builder` version `ubuntu-24.04` installs.
Fixed by adding `"build-options": {"libdir": "lib"}` to the three `cmake-ninja` modules in the chain, individually rather than once at a shared parent: `flatpak-builder`'s own option resolution does not walk an intermediate parent module, only a module's own options and the top-level manifest's, and a single manifest-wide setting would have broken the `autotools`/`meson` modules that currently work by relying on their own different default.
Full account, including why the `autotools`/`meson` modules were confirmed rather than assumed safe: `packaging/flatpak/README.md`'s "fifth defect" section.

The next run past that fix got further and hit the identical shape twice more, each caught by this workflow doing exactly what it exists to do: `libplacebo` (a `meson` module) had the same `lib64` problem the `cmake-ninja` chain did, needing the same `build-options.libdir: lib` fix; and once every module built, the export step itself failed validating the app's icon, because `flatpak build-export` checks icons through gdk-pixbuf **on the CI runner**, and `ubuntu-24.04` carries no gdk-pixbuf image loaders by default.
`librsvg2-common` (confirmed against Ubuntu's own package-contents search for noble/amd64) provides the missing SVG loader; added to both `flatpak-ci.yml`'s and `release.yml`'s `build flatpak` steps, since `release.yml`'s own flatpak build had never gotten far enough to hit this either.
`packaging/flatpak/README.md`'s sixth-defect section and its follow-up section frame all three real defects here (the appindicator soname, the libdir default, this icon loader) as one pattern: the build host leaking into the result in places the sandbox does not cover.

One more failure after that was this workflow's own bug, not the manifest's: `flatpak-builder --repo=dist/flatpak-repo` failed with `Creating repo: mkdirat: No such file or directory`, because nothing in `flatpak-ci.yml` creates `dist/` first.
`release.yml`'s own flatpak step never hits this, because its earlier "stage portable tarball" step already runs `mkdir -p dist` for the tarball; this workflow has no such step, so it needs its own `mkdir -p dist`.
Fixed directly rather than documented as a manifest defect, since it is not one.

### What remains unverified until the fix runs for real

Four fix commits landed in the same PR that introduced this workflow (three manifest defects plus this workflow's own missing `mkdir`), each addressing exactly what the previous run's own log showed; that is what the run linked from the PR confirms or does not.
Once it is green, the build itself (the harder half of this check, and the half that just proved three times over that it can catch a real defect) is confirmed for this exact `flatpak-builder`/CMake/meson/sandbox/runner combination.
Still unconfirmed even after a green build: the launch check's own assertions past that point.
`flatpak-builder` was not available locally while writing the launch-check logic, so the `124`-vs-any-other-nonzero-exit split (see above) is reasoned from documented `timeout` and `flatpak run` behavior, not confirmed against a live launch of this bundle.
It is not yet confirmed that `flatpak run` actually reaches the plugin-loading stage within the 20-second timeout on a GitHub-hosted runner with no display attached at all, that unprivileged flatpak sandboxing works unmodified on `ubuntu-24.04`'s current image, or that some other headless-environment quirk unrelated to a missing shared library (a portal or D-Bus service genuinely absent in that runner) does not also exit nonzero and trip the exit-code assertion.
If a future run fails on exactly that shape, the fix is to loosen the exit-code assertion, not the `grep` patterns, which are the actual defect class this workflow exists to catch.

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

### advisory-watchdog

Nothing watched for a security advisory against a dependency.
`licenses` runs `cargo deny check licenses` and not `check all`, because a CVE published upstream would turn every unrelated pull request red through no fault of its own.
This workflow is the different trigger that reasoning asked for.
It does not gate a pull request or a release and does not report by its own colour, since a scheduled workflow that only fails itself is a red tab nobody opens.
The output is a deduplicated issue that closes itself once the tree is clean.
It runs daily because the RustSec database is published on a human schedule.
It has no concurrency group, because the reporting half is idempotent.

### audio-ci

The notification WAVs are committed and generated from source, and this job regenerates them and fails on drift.
It also runs the family's own checks, the important one being that the seven are level with each other.
The first build of the set passed every per-file check while spanning 3.4 dB, because nothing had compared them.

### red-streak-watchdog

Two workflows fail without anything else noticing.
`e2e` is advisory, and its silence let a multi-day regression ship under two releases (PRs #379 and #550).
`main-builds` puts a build on a phone between releases, and it sat red for five hours on 2026-08-11 with a missing signing profile.
Neither becomes a required check; the watchdog opens an issue instead of adding a second red workflow.
It has no concurrency group, since it runs daily against workflows that run far less often and dedups issues by label.

### client-windows-ci

Compile-only and not a required check.
It was the first CI job to build a Windows target for this client, and `docs/os_backlog/windows_backlog.md` has little confirmed behind it.
A green run proves the native plugin graph links, not that the app runs or that the tray and window-shell features of decision 0012 work.
Read that file before promoting it or building on a green run.
The build is Debug because the job exists to catch link failures, and release packaging runs in `desktop-clients`, on `client-v*` tags only.
