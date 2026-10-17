<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# CI, tests and documentation

The gates that exist are unusually good, and the gaps are all in the same shape: something is asserted rather than enforced.
Route surface is machine-checked against the router, response bodies against the schema, file size and comment runs against per-file ratchets, and every one of those catches real drift.
What is missing is a layer above them.
A pushed tag publishes signed images and moves `:latest` with no test workflow having run on that ref.
The most comprehensive check in the repo, `scripts/e2e.sh`, runs in no workflow at all and can screenshot a stale build without saying so.
Seven public API methods have no caller anywhere in the app, which is the third time this project has paid for that failure shape, and no gate can see it.
And the documentation - which this project treats as instructions, and the CLAUDE.md of the time explicitly called "the durable memory of the project" (that file was rewritten in PR #666; this audit describes the 2,591-line version) - has drifted far enough that two of its lists ask for work that is already shipping, three documents promise codegen and vulnerability scanning that were never built, and one names a source file that no longer exists as the place a permission gate lives.
The stale-documentation set below is listed exhaustively for that reason.
None of it is a product defect; all of it sends the next contributor at the wrong problem.

## Release pipeline and gating

### A pushed tag publishes, signs and retags `:latest` with no tests having run (high)

`.github/workflows/release.yml:51`

Every publish job's `if` carries a tag branch: `|| startsWith(github.ref, 'refs/tags/server-v')` at lines 51-54, 105-108, 171-173 and 229-232, with the client equivalents at 280-283, 425-428, 508-511 and 648-651.
The only `needs:` in the file point at `release-please` and at sibling build jobs.
Every other workflow was checked: server-ci, client-ci, client-ios-ci, schema-ci, hygiene, licenses, perf, compose-smoke, push-relay-contract and audio-ci all trigger on `push: branches` and `pull_request`, and not one has a `tags:` entry.
So on a `refs/tags/server-v*` push, release.yml is the only workflow that runs, and its release-please step is skipped by `if: github.event_name == 'push' && github.ref == 'refs/heads/main'` (line 42) while the job still reports success.
`git tag server-v9.9.9 <sha> && git push --tags` therefore builds both architectures, pushes to GHCR, cosign-signs the merged manifest, moves `:latest` and publishes binaries, with fmt, clippy, `cargo test --all`, the openapi-vs-router contract test, the license gate and the hygiene gates never having executed on that ref.
CLAUDE.md documents hand-tagging as a supported route, so this is a path in ordinary use rather than a theoretical one.
Line 102's comment also calls server-image-merge "Reviewer-gated" when the only mechanism present is `environment: release`, which CLAUDE.md's own owner-items list records as existing but ungated.
Shape of the fix: a verify job on the pushed ref that every publish job `needs`, or removal of the tag branch from the `if`; and either gate the environment or correct the comment.

### `:latest` is retagged unconditionally (medium)

`.github/workflows/release.yml:151`

`docker buildx imagetools create -t "${IMAGE}:${version}" -t "${IMAGE}:sha-${GITHUB_SHA}" -t "${IMAGE}:latest" ${refs}` (lines 151-155), where on the tag path `version` is `${GITHUB_REF_NAME#server-v}` (line 124).
Nothing compares that against the newest published release.
docs/ci.md:269 confirms `latest` is the rolling tag deployments track under Watchtower, and CLAUDE.md confirms the live instance does exactly that.
Deleting and re-pushing an old `server-v*` tag to rebuild an old artifact points `latest` at that version, and the deployment downgrades itself past every fix since within one poll, with no failed job and no notification.
The normal case - re-running a failed release for the current version - moves `latest` correctly, which is why this sits at medium.
Shape of the fix: gate the `latest` retag on the release actually being the newest released `server-v*`.

### Two shipped artifacts are built without lockfile enforcement (medium)

`.github/workflows/release.yml:210` and `.github/workflows/release.yml:320`

The static server binaries run `cargo build --release --target ${{ matrix.target }} --bin slimm-server` with no `--locked`, and it is the only cargo invocation in the repo without it (server-ci.yml:49, :51, :53, perf.yml:38, :49 and docker/server.Dockerfile:22 all have it).
The Linux desktop client runs a bare `dart pub get`, while the four other pub call sites - client-ci.yml:41, client-ios-ci.yml:56, licenses.yml:62, release.yml:576 and :771 - use `flutter pub get --enforce-lockfile`, most of them under a comment saying the lockfile is otherwise advisory.
These are the two artifacts users download, and they are the two permitted to re-resolve rather than fail.
The Linux tarball is also the rpm's Source0 and therefore the COPR input, so the dependency set the license gate cleared is not provably the set in the artifact.
CLAUDE.md records this exact class of drift having bitten once, with the fix reaching CI and the Dockerfile but not these two.
Drift is within-constraint only, not arbitrary, which holds both at medium.
Shape of the fix: the same flags the neighbouring jobs already pass.

### The shipped Linux client reports version 0.1.0 (4) whatever release it came from (medium)

`.github/workflows/release.yml:321`

`flutter build linux --release` is passed neither `--build-name` nor `--build-number`, unlike the android job (lines 579-584) and the ios job (774-776), both of which pass both under a comment saying "never from pubspec".
Flutter therefore reads `client/packages/app/pubspec.yaml`, which is `version: 0.1.0+4` (line 8); release-please tracks `client/pubspec.yaml` (now 0.12.0) and never touches the app package.
The value is user-visible: `client/packages/app/lib/src/widgets/app_info_section.dart:52` renders `'${i.version} (${i.buildNumber})'` from `PackageInfo.fromPlatform()` under a "Version" tile.
Meanwhile the tarball is named from the release version (line 328) and the rpm is stamped with it (line 390), so a tester reads 0.1.0 (4) in Settings for a file that says 0.12.0.
CLAUDE.md's note that the pubspec `+N` is now only a local-build default is true for the store builds and false for this one.
Shape of the fix: the two flags the android and ios jobs already pass.

### No dependency vulnerability scanning exists, and three documents say it does (medium)

`deny.toml:16`, `docs/STRATEGY.md:455`

Found from two directions - the CI specialist reading the gate, the docs specialist reading the claim - which is what raises confidence here.
deny.toml has `[graph]`, `[licenses]`, three `[[licenses.exceptions]]` and `[bans] multiple-versions = "allow"`, and no `[advisories]`.
licenses.yml:42-45 runs `command: check licenses`.
`.github/` contains only `workflows/`, so there is no dependabot.yml, and nothing in the repo runs cargo-audit, osv-scanner, trivy, grype, CodeQL or dependency-review.
Cargo.lock holds 362 packages.
docs/STRATEGY.md:455 states in the present tense that "cargo audit and cargo deny gate Rust, osv-scanner covers Dart, govulncheck covers the relay, and Dependabot keeps all three current".
docs/ci.md:143 is honest about half of it ("Advisories and bans are deliberately not configured here") and cites STRATEGY.md as the source without the source being corrected; the Dependabot and govulncheck halves are unflagged anywhere.
A published advisory against sqlx, axum, tokio or a TLS crate reaches a release with nothing noticing, in a server holding plaintext messages, session tokens and Argon2id hashes.
The gap is a documented deferral rather than an oversight, and ci.md's objection is specifically to a per-PR trigger, which a scheduled job answers.
Shape of the fix: an advisories check on a schedule plus a dependabot config, and narrow the STRATEGY claim to what runs.

### The client SHA256SUMS records the rpm under a path the published asset does not have (low)

`.github/workflows/release.yml:400`

The rpm path is live: `packaging/rpm/slim-m-client.spec` exists, so the `steps.pkg.outputs.rpm == 'true'` gate at line 377 passes.
rpmbuild runs with `--define "_rpmdir /w/dist"` (line 392) and writes to `%{_rpmdir}/%{_arch}/`, so the file lands at `dist/x86_64/*.rpm`.
The checksum step runs `working-directory: dist` with `sha256sum slim-m-client-*-linux-amd64.tar.gz *.flatpak */*.rpm > SHA256SUMS` (lines 397-400), producing a line whose path is `x86_64/slim-m-client-….rpm`, while the upload attaches `dist/*/*.rpm` (line 417) by basename.
A user running `sha256sum -c SHA256SUMS` gets "No such file or directory" on the one artifact most likely to be verified before being installed as root, while the tarball line verifies - which reads as a corrupted rpm.
The server job avoids this by hashing a flat directory (`sha256sum *`, line 258).
Shape of the fix: hash paths that match the published asset names.

### Images are cosign-signed and no operator-facing document says how to verify one (low)

`deploy/README.md:1`

release.yml:159-164 installs cosign and runs `cosign sign --yes "${IMAGE}@${{ steps.manifest.outputs.digest }}"` keylessly.
`cosign` appears in docs/ci.md:264 and :266, docs/ROADMAP.md and docs/STRATEGY.md, all CI-side, and nowhere in the 18KB deploy/README.md, which never mentions signatures or verification.
docker-compose.yml:27 pulls the image with no verification step beside it.
A keyless signature is only worth something to someone holding the expected certificate identity and OIDC issuer, so from the consumer's side the signing step is currently decorative.
Shape of the fix: a verification section in deploy/README.md carrying the identity regexp and issuer, referenced beside the `image:` line.

### compose-smoke asserts server-owned behaviour and never runs for a `crates/` change (low)

`.github/workflows/compose-smoke.yml:9`

Both path filters are `docker-compose.yml`, `deploy/**`, `docker/server.Dockerfile` and the workflow itself (lines 9-19); `crates/**`, `Cargo.toml` and `Cargo.lock` are absent.
The job builds the server from source (line 42) and then asserts on three server-owned contracts: the `--healthcheck` subcommand behind the image HEALTHCHECK (polled at lines 83-92), `/version` containing `"name":"slim-m"` (line 98), and `docker compose logs server | grep -q "voice enabled"` (line 105).
Renaming that log line or changing the `--healthcheck` exit contract are `crates/**` edits this job would catch and never runs for, so the weekly cron finds it days later attributed to nothing.
The trigger set is deliberate and reasoned in docs/ci.md:180; what the doc does not address is that three assertions read strings owned by `crates/`.
Shape of the fix: widen the filters, or move the three server-contract assertions into the Rust suite.

### The committed `.sqlx` cache is never validated against the migrations (low)

`.github/workflows/server-ci.yml:36`

`SQLX_OFFLINE: "true"` is workflow-wide in server-ci.yml:35-36 and perf.yml:25-26, and `ENV SQLX_OFFLINE=true` sits at docker/server.Dockerfile:19.
No job runs `sqlx migrate run` followed by `cargo sqlx prepare --workspace --check`.
An offline build catches a missing cache entry, because the cache is keyed on query text and a new or edited `query!` fails to compile.
It does not catch a stale one: a migration that renames or retypes a column while the cached entry keeps the old shape compiles green in CI and in the Docker build.
The exposure is narrow - a migration-side change with no query-text change, for a macro query no integration test drives - but cache regeneration is documented as a step a human must remember.
Shape of the fix: one job that migrates a temp database and runs the `--check` form.

### The binary-size budget measures a glibc host build, not the musl binary that ships (low)

`.github/workflows/server-ci.yml:52`

`cargo build --locked --release --bin slimm-server` with no `--target`, then `size=$(stat -c%s target/release/slimm-server)` against `max=20971520` (lines 52-63) - the ubuntu-latest host triple, dynamically linked against glibc.
Every shipped artifact is static musl: release.yml:178-183 builds both musl targets, and docker/server.Dockerfile:16-22 builds on `rust:1-alpine`.
A static musl binary carries libc that the measured one links dynamically, so the gate can pass on a binary nobody receives while the one they do receive is over.
The step's own comment says the brief treats binary size as a first-class budget, and the number gated is not the number in the budget.
Shape of the fix: measure a musl target, or move the assertion to the artifact job and accept that it stops gating PRs.

### The perf job benchmarks the server on every release, including client ones (low)

`.github/workflows/perf.yml:42`

Trigger is `release: types: [published]` with no tag filter (lines 14-15), `benchmark` gates only on `if: github.event_name == 'release'` (line 43), and it runs `cargo bench --locked -p slimm-server` (line 49), uploading `criterion-report-${{ github.event.release.tag_name }}` with 90-day retention.
Both components publish releases, so a `client-v*` release yields `criterion-report-client-v0.13.0` holding a Rust server benchmark.
CLAUDE.md records the perf baselines as hand-curated from these artifacts, so a mislabelled one is a trap for whoever curates.
docs/ci.md:166 explains why the release job is not path-gated and says nothing about tag scope.
Shape of the fix: scope the condition to `server-v` tags.

### The Docker build has no dependency layer and no buildx cache (low)

`docker/server.Dockerfile:21`

`WORKDIR /build` / `COPY . .` / `RUN cargo build --locked --release --bin slimm-server` (lines 20-22) puts sources and manifests in one layer, and `cache-from`/`cache-to` appear nowhere in `.github/workflows/` - release.yml:79-88 passes context, file, platforms, outputs, sbom and provenance only, and compose-smoke.yml:42 is a bare `docker build`.
So all 362 crates recompile on every image build, on both architectures.
.dockerignore excludes `/target`, `/data`, `/client`, `.git`, `.github`, `docs`, `*.db*` and `.env*`, but not `assets/`, `scripts/`, `deploy/`, `packaging/`, `perf/` or `schema/`, so editing a shell script invalidates the build layer as thoroughly as editing store.rs.
Held at low because compose-smoke only triggers on stack paths plus a weekly cron and a release is two builds, so this is minutes of runner time on a handful of runs rather than a per-PR cost.
Shape of the fix: a dependency layer or cargo-chef, GHA buildx cache, and a tighter .dockerignore.

## The test suite: gaps and false assurance

### Seven public `SlimmApi` methods have no call site in the app (high)

`client/packages/api/lib/src/client_users.dart:16`

Verified individually by grepping outside `packages/api/lib`: `updateMe` (client_users.dart:16), `resetPassword` (client_admin.dart:21), `issueResetCode` (client_admin.dart:12), `kickVoiceParticipant` (client_voice.dart:23), `listUsers` (client_users.dart:28), `pinnedMessageCount` (client_messages.dart:172) and `canvasViewport` (client_canvas.dart:15) each return only their own definition, plus one api-package unit test for `pinnedMessageCount`.
Nothing under `packages/app/lib` mentions any of the seven.
Corroborated at the UI level: `reset code` and `reset password` return nothing across `packages/app/lib`, and personal_settings_screen.dart only reads `me.displayName` (lines 127, 137) with no edit path.
`health()` is called only from `packages/api/test/live_server_test.dart:77`, which returns early without `SLIMM_TEST_SERVER`.
This is the failure shape the project has already paid for three times - `Routes.settings` unreachable for a whole release, `markRead` with no call site leaving unread badges permanently lit, report and blockUser with endpoint, model and screen but no callers.
`resetPassword` and `issueResetCode` together are the entirety of the owner decision that self-hosted recovery is an admin-issued one-time reset code, and both are unreachable in the client while unit tests assert each decodes correctly.
Neither existing gate can see it: route_reachability_test.dart reads `static const (\w+) =` out of routes.dart only, and schema_coverage_test.dart scans the api package's own `_send` call sites, not consumption by the app.
Shape of the fix: a reachability test in `packages/api` over public method names against `../app/lib`, with a reasoned allowlist that fails on a stale entry - the shape `tests/response_contract`'s `UNCOVERED` already uses. `canvasViewport` is a legitimate Phase 6 entry.

### The iOS broadcast-extension test asserts only the direction the bug was already in (high)

`client/packages/rtc/test/voice_session_test.dart:346`

The test "the iOS broadcast flag tracks the platform, never hardcoded on" calls `VoiceSession.captureOptionsFor(ScreenShareQuality.balanced, 'screen-2')` on a Linux host and asserts `useiOSBroadcastExtension` is false and `deviceId` is `'screen-2'`.
Production is voice_session.dart:308, `useiOSBroadcastExtension: lk.lkPlatformIs(lk.PlatformType.iOS)`, inside a static method whose signature carries no seam for the platform.
Editing that line back to a literal `false` - exactly the original double-broadcast bug CLAUDE.md records - satisfies both assertions.
CLAUDE.md also records that fix as unconfirmed on a device because there is no Mac or simulator here, which makes this test the only guard on it.
It does guard the "simplify to true" direction its comment claims; the regression direction is invisible, and the direction that matters (true on iOS) is untestable as the function is written.
So the suite records assurance it does not have on the highest-risk untested path in the product.
Shape of the fix: pass the platform in, or inject a predicate the way `desktopSources` is already injected on the same class, then assert both halves.

### No real app screen is laid out above 100% text scale (medium)

`client/packages/design_system/test/golden_matrix_test.dart:37`

`textScaler` appears in exactly two test files across the client: golden_matrix_test.dart:192, which sweeps 1.0 and 2.0 across themes and viewports, and theme_preference_test.dart:117, which uses 1.3 on one widget.
What golden_matrix renders is `_sample(tokens)`, described by its own comment as "a representative slice of chrome: a header, a selected and unselected row, and a body message ... without pulling in the whole app and its providers".
ui_snapshot_test.dart's axes are viewport and theme only, with no scale.
So 2.0 is the accessibility ceiling the roadmap commits to, and the only thing ever rendered at it is a hand-built Column - none of the eleven real routed screens is laid out above 1.0 by anything.
The pixel half of golden_matrix is behind `bool.fromEnvironment('SLIMM_GOLDENS')` with no committed references, so the file's doc comment ("only a rendered comparison catches it") describes the half that does not run.
Shape of the fix: a scale axis on `_surfaces` in ui_snapshot_test.dart, even one entry, which puts real screens under the existing overflow assertion; and correct golden_matrix's doc comment to describe what runs.

### The snapshot fixture's route table is hand-written, has drifted, and CLAUDE.md overstates it (medium)

`client/packages/app/test/ui_snapshot_support.dart:262`, `CLAUDE.md:73`

Found independently by the tests specialist (reading the fixture) and the docs specialist (reading the claim).
`fixtureRouter` declares its own GoRouter with eight standalone routes plus the shell; routes.dart declares eleven non-channel routes and router.dart registers all eleven.
Missing are `Routes.adminRemovedMembers` (`/settings/removed-members`) and `Routes.debugLog` (`/settings/debug-log`), and neither screen has a widget test anywhere - `RemovedMembersScreen` and `DebugLogScreen` return nothing under `packages/app/test`.
CLAUDE.md:73 claims the harness "now renders all 12 routed screens ... so the settings/admin screens sit under the CI overflow gate".
`expect(tester.takeException(), isNull)` in ui_snapshot_test.dart is the only machine check that any real app screen fits a phone viewport, so those two screens have no layout gate at any width in either theme.
The render count in that sentence is also wrong: 2 shell surfaces across 5 viewports plus 9 standalone across 2, doubled for themes, is 56 rather than 60.
Nothing fails when the next route is added; the fixture quietly covers less of the app than the doc says.
Shape of the fix: assert every `Routes.*` constant appears in the fixture and in `_surfaces` or a reasoned exemption list, reading routes.dart the way route_reachability_test.dart already does.

### The one test file that loads real fonts silently no-ops its icon loader in two reachable configurations (medium)

`client/packages/app/test/ui_snapshot_support.dart:79`

`FontLoader` appears in exactly one file across the client.
The two IBM Plex families load unguarded (lines 68-76, a missing file throws), but Lucide is guarded twice and a miss is silent: `if (lucide.existsSync())` at line 81 and `if (lucide300.existsSync())` at line 87.
`_pubCache()` (lines 92-95) is `Platform.environment['PUB_CACHE'] ?? '$home/.pub-cache/hosted/pub.dev'`, and the two branches sit at different depths - verified on this box, the HOME branch resolves while the PUB_CACHE branch would look one level too shallow.
`_lucideVersion()` (lines 99-111) scans `j` in `i..i+8` for a `version:` line; in the current client/pubspec.lock the key is at 675 and the version at 682, i.e. i+7, one line of slack.
The function's own doc comment says an unloaded icon font "renders every icon as an empty square, which reads as a layout bug in the PNG rather than as a missing font", and then swallows exactly that case twice.
Square boxes have different metrics from real glyphs, so the CI overflow assertion would be measuring a layout no user sees, and passing.
Both triggers are reachable without anyone editing the file: an environment that sets PUB_CACHE, or pub adding one field to a lockfile description block.
Whether the CI action currently sets PUB_CACHE was not confirmed, so treat this as latent; the silent guard stands either way.
Shape of the fix: fail loudly naming the path it looked for, resolve both branches to the same depth, and widen or drop the i+8 window.

### `new_store`, `app` and `request` are copy-pasted across 38, 27 and 26 test files (medium)

`crates/slimm-server/tests/support/mod.rs:1`

`async fn new_store` appears in 38 test files, `fn app(store: Store) -> Router` in 27, `fn request(method` in 26.
Normalising whitespace, 22 of the `app()` bodies are byte-identical (`http::router(AppState { store, auth: Auth::new(2).unwrap(), hub: Hub::new(), limiter: RateLimiter::new(), push: PushSender::disabled(), ... })`), with five one-off variants differing only in an injected field, `state_for(&store)`, or `expect` versus `unwrap`.
tests/support/mod.rs is 64 lines, exports only `TestDbGuard` and `TestDirGuard`, and is already included by every test binary.
CLAUDE.md records the cost of this exact shape in production code: `Config` had no `Default` impl and "38 files built it as a struct literal, so every new setting was a 38-file edit. That cost is why the attachments work first read its settings straight from the environment, creating a second configuration mechanism."
The test tree now has the same shape and the same arithmetic, and each copy picks its own `Auth::new(2)` and its own fresh `RateLimiter`, so a test's effective configuration is per-file and can drift silently.
Shape of the fix: move the four helpers into the module that already exists and is already wired in, with injected variants taking the differing piece as a parameter.

### Five hand-written `implements VoiceSession` fakes (medium)

`client/packages/app/test/screen_safe_area_test.dart:81`

`implements VoiceSession` appears in voice_settings_screen_test.dart, voice_call_controls_test.dart, voice_screen_test.dart, screen_safe_area_test.dart and voice_controller_harness.dart.
The `_FakeSession` in screen_safe_area_test.dart runs from line 81 into the 170s, and all five carry the same `Widget screenShareViewFor(String identity) => SizedBox.shrink(key: Key('fake-share-view-$identity'));` line.
CLAUDE.md names the bill directly: when `screenShareViewFor` was added, "Every fake implementing VoiceSession had to grow the method."
`implements` fails at compile time, so the cost is divergence rather than breakage - five independent notions of what joining, muting and sharing do, so a widget test can assert against behaviour the real session does not have (`join` completing synchronously, where the real one serializes overlapping calls).
voice_controller_harness.dart already exists as the place this belongs.
Shape of the fix: one configurable fake the other four take, overriding only the member each test cares about.

### The oversized-upload test asserts only `!is_success()` (low)

`crates/slimm-server/tests/attachments/uploading.rs:36`

`assert!(!response.status().is_success(), ...)` is the whole assertion in `an_oversized_upload_is_refused`.
Following the two layers: src/http/attachments.rs:47 layers `DefaultBodyLimit::max(max_attachment_bytes as usize)` on the route and src/http/error.rs:65 maps a body-limit rejection to `PAYLOAD_TOO_LARGE`, while the handler's own `ApiError::BadRequest("attachment is too large")` (attachments.rs:103) sits behind that layer.
So over HTTP the answer is determinately 413 and the 400 branch is unreachable defence in depth.
The test passes if the role grant on lines 15-22 silently stops working (403), if auth breaks (401), or if the handler 500s - none of which is the behaviour it names - and a change that moves the ceiling between the two layers, changing the status a client sees, is invisible.
Shape of the fix: assert 413 exactly, and cover the 400 branch directly so the split between layers is pinned.

### A conditional assertion in message_row_test can skip the panel-to-row wiring check (low)

`client/packages/app/test/features/messages/message_row_test.dart:443`

`final tile = find.byType(InkWell).hitTestable(); if (tile.evaluate().isNotEmpty) { ... expect(picked, isNotNull, ...); }`, where `picked` is assigned by `onPickReaction` at line 406 and read nowhere else.
`hitTestable()` yields an empty finder whenever the tiles land outside the viewport or under another layer, and the assertion then never runs while the test passes.
reduce_motion_test.dart:161-163 deliberately fixed this exact shape, with a comment saying "Without this the loop below passes on an empty match: widgetList returns an empty iterable rather than failing, so the assertion never ran and the test proved nothing."
Narrower than it first looks: emoji_picker_test.dart:148 and :274 assert `picked` at the panel level, so what is conditionally skipped is the MessageRow-to-panel wiring of `onPickReaction`, and the test's primary assertion runs unconditionally.
Shape of the fix: assert the precondition rather than branching on it.

### The typing TTL-refresh test races the wall clock with about 50ms of margin (low)

`crates/slimm-server/tests/typing.rs:262`

`Hub::with_typing_ttl(Duration::from_millis(400))`, typing sent, `sleep(300ms)`, a refresh, then a `timeout(350ms)` read that must expire.
The refresh has about 100ms of slack against the original 400ms deadline, and the silence window ends around t=650ms against a refreshed deadline of t=700ms.
Both margins are thin on a runner executing the whole suite in parallel: if the refresh slips, a `typing.stopped` frame arrives and the test fails for reasons unrelated to the behaviour.
No flake is on record, so this is risk rather than an observed defect, and the seam is already injectable (hub.rs:162; the sibling test at typing.rs:217 uses 150ms).
Shape of the fix: a much larger TTL with proportionally the same refresh point.

### Two assertion messages escape their interpolation (low)

`client/packages/design_system/test/components/semantics_test.dart:127`

Inside `for (final status in AppPresence.values)`, the reasons read `'\$status has no accessible name'` (line 127) and `'\$status is announced by colour rather than by meaning'` (line 131), so each is a literal `$status`.
The loop covers all five presence states, so a failure cannot say which one, and this is the check guarding "presence is never colour alone" - one of the two accessibility invariants CLAUDE.md calls out as worth not breaking.

### The onboarding test hardcodes the server-identity pin handle (low)

`client/packages/app/test/features/auth/onboarding_screen_test.dart:54`

The test defines `String _handleFor(String server) => 'server_identity:$server';` and uses it at lines 161, 185, 192, 220, 255, 267 and 288, while production is server_identity_confirmation.dart:19, `'server_identity:${address.origin}'`.
They agree only because the fixture's server string is already an origin.
The TOFU coverage here is otherwise the strongest in the suite - all five branches including pin-overwrite and cancel-leaves-old-pin - but a change to the production derivation (URL normalisation, a version prefix) leaves the test green while every existing pin is orphaned, which downgrades a real identity change to a silent first-use prompt.
Separately, the `catch (_) { return true; }` at lines 39-41 of that widget has no test: the covered "too old" case reaches `if (identity == null) return true;` on line 43 instead, and none of the file's `testWidgets` makes the probe client throw.

### scripts/ui-snapshots.sh has no SPDX header (low)

`scripts/ui-snapshots.sh:1`

Line 1 is the shebang and line 2 is a description comment.
Checking `head -3` for SPDX across scripts/*.sh, scripts/*.py and scripts/lib/*.py flags this file and no other; e2e.sh carries `# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0` on line 2.
CLAUDE.md requires the header on every source file and the hygiene gate only checks the Rust ones, so it slipped through - the single exception in an otherwise clean scripts tree.

## The end-to-end harness

### It runs in no workflow, so the most comprehensive check in the repo can rot unobserved (medium)

`scripts/e2e.sh:1`

Both the CI specialist and the tests specialist found this independently; the CI reading is the more severe one and is taken here.
`grep -rn e2e .github/workflows/` returns nothing across all eleven workflow files, and docs/ci.md never mentions e2e in any form.
scripts/e2e.sh plus thirteen modules under scripts/lib/ (e2e_run, e2e_voice, e2e_messaging, e2e_admin, e2e_settings, e2e_coverage, e2e_sweep, e2e_api, e2e_client, e2e_fixtures, e2e_js, e2e_labels, e2e_seed) run only by hand, and nothing in docs/e2e.md says local-only is deliberate.
docs/e2e.md and CLAUDE.md describe this as nineteen scenarios reaching 36 of 59 documented API paths across voice, messages, reactions, attachments, avatars, roles, moderation and screen share, checked against a real LiveKit SFU and the real server binary - and as the thing that closed the longest-open Phase 4 exit criterion.
None of it protects main, and its labels are a contract with the UI (e2e_labels.py's own docstring says so), so a renamed semantic label breaks a scenario with nobody watching.
Shape of the fix: a scheduled and dispatchable run before any PR subset, with the rebuild forced and screenshots uploaded.

### A run can screenshot a build that is not in the tree (medium)

`scripts/e2e.sh:96`

`if [[ ! -f "$WEB_DIR/main.dart.js" || -n "${E2E_REBUILD:-}" ]]; then ( cd "$ROOT/client/packages/app" && flutter build web --release ); fi` - existence only, no comparison against any client source mtime or hash, and nothing printed when the cache is used.
CLAUDE.md records the cost already paid: "a verification run after a client change *must* set it, or it screenshots the old build (that cost one confused cycle)".
As written, every UI-side assertion in the run - scenario labels, the crop sheet, the settings screens, the sharing notice - can pass against a build predating the change under test, with no hint in the output.
A false green that looks like a successful verification is the most expensive kind.
Shape of the fix: compare source mtimes against the built bundle, and at minimum print the cached build's timestamp loudly.

### The screen-share scenario asserts nothing on the viewing side (medium)

`scripts/lib/e2e_voice.py:77`

`share_screen(client, other, room_id)` asserts a SCREEN_SHARE track reached the SFU (deadline loop, lines 88-99), a sharing notice on the publishing client (line 101), and the track going away on stop (lines 107-117).
The only thing it does with `other` is line 103, `other.shot("peer-sharing-screen")` - a screenshot, no assertion - followed by printing "the sharing client says so on screen".
There is a widget backstop, correcting the original claim: voice_share_indicator_test.dart:118 asserts the stage mounts for the sharing peer and :147 asserts no echo stage for your own share.
But that key comes from the test fake's `screenShareViewFor`, so the real renderer - screen_share_view.dart, which listens to room events itself because the track arrives after the roster flips - is stubbed out in every widget test and has no assertion anywhere.
CLAUDE.md records that the receiving half is the one that had never existed ("the e2e proved subscription at the SFU while the viewer's pane rendered a roster glyph and nothing else"), caught by a human looking at the PNG.
So the exact regression already hit once would still print PASS.
Shape of the fix: one semantic assertion on the viewer after the SFU confirms the track.

### Read-state and sync assertions are `is not None`, under a docstring disclaiming exactly that (medium)

`scripts/lib/e2e_sweep.py:178`

In `devices_and_read_state`: a `PUT /channels/{id}/read` with the latest seq, then `assert api.call("GET", f"/channels/{channel_id}/read") is not None`, and three lines later `assert synced is not None, "sync answered nothing"` for `POST /sync`.
Neither compares against `latest["seq"]` nor inspects the delta, so any JSON body satisfies both - including `{"last_read_seq": 0}` or an empty delta.
The module docstring at lines 7-8 promises these "call the API directly and check the effect rather than the status code, so a route that answers 200 and stores nothing still fails".
CLAUDE.md records read state as "a dead feature in both directions", and this is the only end-to-end check over it.
Neighbouring functions in the same file do it properly: `channel_admin` asserts the deleted channel is gone, and `change_join_policy` polls the server and cross-checks `/version`.
Shape of the fix: assert the values, both of which are one field read from what is already fetched.

### Two settings scenarios assert only a local label while their docstrings claim persistence and server state (medium)

`scripts/lib/e2e_settings.py:37`

`change_theme(client)` is docstringed "A preference that persists is a preference that was actually stored" and ends at `client.wait_for('Theme, currently Dark')` - no reload, no storage read.
`change_status(client)` is docstringed "Presence is a real server-side state, not a local badge", takes no `api` argument at all, and ends at `client.wait_for('Status, currently Do not disturb')`.
Both are called from e2e_run.py:82-84 under a module docstring promising "that what they change actually changes".
Each asserts only that the control just tapped relabelled itself: `change_status` passes with the presence PATCH removed entirely, which matters because appear-offline is enforced structurally at four separate surfaces and a silently non-persisting status is a privacy failure rather than a cosmetic one.
Two functions later `change_join_policy` does it properly, which is the pattern available.
Shape of the fix: poll the server for presence the way join policy is polled, and reload the page before re-reading the theme label.

### The mute check reads `tracks[0]` behind the file's only unpolled wait (low)

`scripts/lib/e2e_voice.py:119`

`mute_propagates` clicks mute, `time.sleep(4)`, then builds `{identity: p["tracks"][0].get("muted", False)}` and asserts `any(muted.values())` and `not all(muted.values())`.
The same module defines `tracks_of(participant, source)` at line 43 and uses it correctly in `join_call` and `share_screen`; it is not used here.
The stale-screen-share worry does not survive - `share_screen` ends by asserting no SCREEN_SHARE track remains - but `tracks[0]` still relies on an ordering LiveKit does not promise, and `any`/`not all` is a weaker claim than the scenario prints ("exactly one side muted").
Every other SFU check in the file loops to a deadline; this is the only bare sleep, which makes it the flake risk under load.

### Coverage is printed rather than asserted, and counts paths rather than operations (low)

`scripts/lib/e2e_coverage.py:52`

`report()` computes covered, missing and a percentage, prints two lines and returns them; e2e_run.py:143-145 calls it while the run's exit status depends solely on `failures`.
Coverage is keyed on `canon(path)` with no method anywhere, and `documented()` collects path keys from the `paths:` block, so `/reports` is one entry however many methods it mounts.
There is no floor, so coverage can fall from 36/59 to anything and the run still prints PASS - the number CLAUDE.md quotes is an observation, not a guarantee.
The path-level count is also the specific overstatement CLAUDE.md warns about for the capability probe, where GET `/reports` is the moderator queue and POST is a member filing one, and "a path-only probe reads a deployment that kept the queue and dropped the intake as still offering reporting, which is exactly backwards".
Shape of the fix: record method-and-path, count documented operations, and fail below a committed floor the way the file-budget allowlist works.

## The hygiene gates themselves

### The comment-cap counter reads stacked Rust attributes as comment runs (low)

`scripts/check-comment-cap.sh:45`

Verified by instrumenting the same awk: `/^[[:space:]]*#([^!]|$)/` matches `#[derive(...)]`, `#[sqlx(...)]`, `#[tokio::test]` and `#[ignore = ...]`, excluding only inner attributes.
Three allowlist ceilings are therefore phantom.
`crates/slimm-server/src/ids.rs` counts 2 runs (lines 14-16 and 49-50), both pure attribute stacks, against a ceiling of 2 at comment-cap-allow.txt:187.
`crates/slimm-server/src/permissions.rs` counts 1 (lines 27-28, `#[derive]`/`#[sqlx(transparent)]`) against a ceiling of 1 at line 190.
`crates/slimm-server/tests/canvas_spike.rs` counts 6, of which 5 are `#[tokio::test]`/`#[ignore]` pairs and only lines 85-86 are a real comment, against a ceiling of 6 at line 219.
Repo-wide the miscount is 11 of 240 counted Rust runs, so the effect is concentrated in these three files rather than spread.
The gate is a ratchet, so ids.rs and permissions.rs can each take on a real multi-line comment run and canvas_spike.rs five with CI staying green, and a contributor who cleans a file cannot lower its entry to a truthful number.

### The comment cap skips shell, YAML and TOML, and the workflows are the largest concentration of in-scope runs (low)

`scripts/check-comment-cap.sh:62`

`case $file in *.sh | *.yml | *.yaml | *.toml) continue ;; esac`, under a comment saying they are "out of scope entirely rather than counted wrongly".
CLAUDE.md scopes the exemption narrowly to "a `#` block at the very top of the file", with "a `#` block anywhere else in those files ... capped at one line like everything else".
Counting only runs after the leading header block: release.yml 33, docker-compose.yml 17, hygiene.yml 13, compose-smoke.yml 13, client-ios-ci.yml 8, Cargo.toml 8, push-relay-contract.yml 6, schema-ci.yml 4, check-comment-cap.sh itself 3, perf.yml 3, client-ci.yml 3, audio-ci.yml 3, e2e.sh 2, client/pubspec.yaml 2, server-ci.yml 1.
So the one rule tightened by owner decision on 2026-07-27 is unenforced across the files a reviewer reads most, including the script that enforces it.
This is a rule-versus-gate mismatch to settle rather than a defect: the exemption is an explicit documented simplification in the script header.

### Swift and Kotlin are outside the comment cap, which the sibling file-budget gate covers (low)

`scripts/check-comment-cap.sh:77`

`done < <(git ls-files '*.dart' '*.rs' '*.py')`, while scripts/check-file-budget.sh:32-34 walks fifteen extensions including `*.swift`, `*.kt`, `*.kts`, `*.sql`, `*.yml` and `*.gradle`.
Running the script's own `//` branch over the excluded files: android/app/build.gradle.kts 6 runs, ios/Runner/AppDelegate.swift 3, ios/RunnerTests/VoipCallHandlerTests.swift 3, ios/Runner/VoipCallHandler.swift 2, and one each in RunnerTests.swift, android/build.gradle.kts, android/settings.gradle.kts and all five ios/BroadcastExtension/*.swift.
The iOS broadcast extension and the CallKit handler are the code CLAUDE.md documents as failing silently when wrong, so they are the code most in need of durable why-comments and the code the cap does not reach.
Two sibling gates disagreeing on the file set is also the kind of thing that quietly stays wrong.
On the related SPDX question: eight non-generated non-Rust files carry no header, not two, but CLAUDE.md's own rule text says "a CI gate checks the Rust ones", so hygiene.yml:265 scoping `find crates -name '*.rs'` is the documented scope rather than a gap - a separate, smaller decision about whether to widen it or rename the step.

### `SLIMM_GOLDENS=1` cannot enable goldens by either mechanism, and docs/ci.md describes a gate that does not exist (low)

`docs/ci.md:43`

docs/ci.md:43 says "goldens are generated and verified on the same `stable` channel on `ubuntu-latest`", and :44 tells you what to do "if goldens start flaking across runs" - both read as a live gate.
No golden PNGs are committed and no workflow sets `SLIMM_GOLDENS`.
The flag is `const bool.fromEnvironment('SLIMM_GOLDENS')` at golden_matrix_test.dart:228 and presence_desaturation_test.dart:215, a compile-time declaration reachable only via `--dart-define`, and `bool.fromEnvironment` accepts only "true"/"false", so even `--dart-define=SLIMM_GOLDENS=1` evaluates false.
The sibling harness reads a real environment variable (`Platform.environment['SLIMM_UI_SNAPSHOTS'] == '1'`, ui_snapshot_support.dart:45) and scripts/ui-snapshots.sh sets it that way.
Two mechanisms spelled the same way in prose: `SLIMM_GOLDENS=1 flutter test` silently does nothing while `SLIMM_UI_SNAPSHOTS=1 flutter test` works, so a contributor following the doc concludes the golden path is broken rather than that they invoked it wrong.
golden_matrix_test.dart:13-18 is itself accurate and matches CLAUDE.md; the layout assertions that do the real work run unconditionally.

### docs/ci.md omits three of hygiene's seven gates, including the comment cap (medium)

`docs/ci.md:20`

hygiene.yml runs seven named steps: iOS purpose strings (:24), iOS broadcast extension wiring (:48), orientation locked on phones only (:185), no emoji in UI source (:244), SPDX headers on Rust source (:257), file size budget (:269) and comment cap (:274).
docs/ci.md:20's glance row names four and its `## hygiene` section (:85-121) documents three.
`comment cap`, `check-comment-cap`, `comment-cap-allow` and `orientation` all return nothing from docs/ci.md, while the script and its allowlist both exist.
ci.md:5-8 states its own contract - a workflow YAML has no doc-comment mechanism, so "Anything that needs more room than that lives here" - which means a gate absent from ci.md has no durable written why.
The comment cap in particular is a ratcheting mechanism whose design is described only in the script's own header.
One correction to the original finding: ci.md:17 does not misattribute hygiene's extension check; it names client-ios-ci's own "the broadcast extension embeds no frameworks" check, which is real (client-ios-ci.yml:80).
The defect is that hygiene's separate extension-wiring check appears nowhere, and that the two iOS extension gates are different checks in different workflows with only one documented.

## Documentation accuracy

This project treats its documentation as instructions, so each of these is listed with the evidence that contradicts it.

### Documents that promise a machine guarantee nothing provides

**schema/README.md asserts codegen and a CI drift gate (high)** - `schema/README.md:5`.
It says "The Rust server types and the Dart client types are both generated from this file. / CI regenerates both and fails on any diff, so the schema and the code cannot drift", and closes with "Phase 0 defines only the liveness and version endpoints. / The messaging, auth, RBAC, sync, and WebSocket-envelope definitions are added in Phase 1."
schema/openapi.yaml's own header in the same directory refutes both, at lines 1-24: "No types are generated from this file; the Rust DTOs and the Dart models are both hand-written, and only the Rust side is compared against what is written here."
A yaml parse gives 62 paths and 84 operations; `ls schema/` returns exactly those two files; no workflow contains a codegen step.
The identical falsehood was found and corrected in openapi.yaml's header during the phase-3 audit and the correction never reached the README beside it, so anyone trusting it will hand-edit a DTO expecting CI to catch the drift - exactly the gap openapi.yaml's header names.

**STRATEGY.md records schema-driven codegen as a decision, and ROADMAP does not flag it as unmet (medium)** - `docs/STRATEGY.md:432`.
Three passages: :432 "a schema codegen job that regenerates Rust and Dart types and fails on any diff"; :34 "one OpenAPI plus JSON Schema source of record generates both the Dart and Rust types, CI fails on any drift"; :229 the same at length, naming JSON Schema for the WebSocket envelope.
There is no ci.yml among the eleven workflows, no codegen step in any of them, and `find . -name '*.schema.json'` is empty.
docs/ROADMAP.md:32 carries the same deliverable and its Phase 0 "Status (2026-07-28)" at :46-61 names only flatpak and TestFlight as open, never mentioning codegen.
CLAUDE.md names STRATEGY.md as core reading, so this makes a reader believe cross-language type safety is mechanised, and it hides a real architectural fact: the WS envelope has no JSON Schema and lives incompletely inside the OpenAPI document.
CLAUDE.md:620 and README.md:17 repeat the claim.
The repo's own convention supports correcting in place - STRATEGY.md:435 already carries a "Corrected 2026-07-28:" annotation for a different wrong claim.

**STRATEGY.md claims four supply-chain scanners plus Dependabot (medium)** - `docs/STRATEGY.md:455`.
Covered above under CI, since the gate and the claim are one finding seen from two sides.

**openapi.yaml's header says the response contract drives "every operationId" (low)** - `schema/openapi.yaml:12`.
Lines 12-17 say the contract test "drives every operationId below for real ... and an operation the test never drives fails too, so coverage cannot quietly lapse".
tests/response_contract/main.rs:46 defines `const UNCOVERED: &[(&str, &str)]` with three reasoned exemptions - `kickVoiceParticipant`, `listVoiceRoster`, `connectWebSocket` - skipped at lines 92-101.
The mechanism is honest in itself (main.rs:79-89 fails on a stale entry in both directions); "every operationId" is what is false, and it matters most for `connectWebSocket`, whose exemption is why the next finding went unnoticed.

### The WebSocket half of the protocol has no gate at all

**openapi.yaml documents 9 of the 15 server frames (high)** - `schema/openapi.yaml:3871`.
`ServerFrame.oneOf` at lines 3873-3882 lists ServerHello, MessageCreated, MessageEdited, MessageDeleted, PresenceChanged, TypingStarted, TypingStopped, ServerPong and ServerError.
crates/slimm-server/src/http/ws.rs:73-131 serialises fifteen variants: those nine plus `reactions.changed`, `message.pinned`, `message.unpinned`, `poll.voted`, `member.timeout` and `member.removed`, all six of which the client already parses (client/packages/api/lib/src/events.dart:49, 60, 70, 77, 95, 101).
Nothing gates it: the response contract exempts `connectWebSocket` as "an upgrade, not a request/response", and the oasdiff gate is breaking-change only, so a missing oneOf member is invisible.
openapi.yaml calls itself the single source of record for the wire protocol, and the oneOf is the only written description of the event envelope, so a third-party client or an iOS Notification Service Extension written from the schema would silently drop reactions, pins, poll tallies and both moderation events.
The item shapes at ws.rs:135-155 (`ReactionCountDto`, `PollOptionCountDto`) are undocumented for the same reason.

### Stale gaps: work described as open that is done

The rule the CLAUDE.md of the time stated applies to every entry here, and it did not survive the PR #666 rewrite: "A stale gap costs more than a missing one, because it sends work at a problem that no longer exists and gets quoted forward into later documents as though still live."

| Claim | Where | Reality |
| --- | --- | --- |
| Three features "genuinely still open": member profile popover, per-participant volume, timeout/kick on member rows (high) | docs/research/nine-specialist-audit-2026-07-29.md:88 | All three shipped. member_profile.dart, member_profile_sections.dart and member_actions.dart exist (4ef62de, #134); timeout and removal are wired at member_profile.dart:211, 232, 238-254 (e746bcd, #138); per-participant volume is rtc/lib/src/audio_gain.dart, exported and consumed at member_profile_sections.dart:235 with a per-platform support guard. Edit history, saved items and low-bandwidth mode do stand. This is the one document whose stated job is preventing re-discovery. |
| `packaging/rpm/*.spec` does not exist, so releases skip both Linux artifacts (medium) | CLAUDE.md:524, repeated on the owner list at :757 | packaging/rpm/ holds slim-m-client.spec plus a desktop file and README; packaging/fedora/ and packaging/linux/ also exist; release.yml has both a `linux-client` job (:278) and a `copr` job (:423); ROADMAP:49 records COPR actually receiving client 0.6.0 on 2026-07-28. Only the flatpak half holds. CLAUDE.md contradicts itself three sections apart: :323 opens "The rpm was installed and used" and :350 discusses that spec's `Recommends` line. |
| The channel-rail semantics bug is "unexplained" and wants a widget test (medium) | CLAUDE.md:428 | client/packages/app/test/shell_semantics_test.dart is that test, and its library doc at lines 2-13 gives the root cause: a modal barrier inside the conversation pane's navigator carries `BlockSemantics(blocking: true)`, dropping everything painted before it - the rail paints before that pane and the member pane after, which is why only the rail vanished. The note sends the next contributor at a disproved Flutter-web hypothesis and loses a durable widget-tree constraint. |
| The voice join preview does not show the roster, and `MediaCapabilities.probeAll()` has no caller (medium) | CLAUDE.md:437, :439 | voice_screen.dart:209 is `final roster = ref.watch(voiceRosterProvider(channelId)).valueOrNull;`. media_capability_section.dart:43 is `final results = await ref.read(mediaCapabilitiesProvider).probeAll();`, the only call site and a real one. ROADMAP:180 and :182 already record both closed, so the two documents disagree and the wrong one is the file CLAUDE.md:4 calls read-first. |
| Reactions UI, the quick switcher and haptics are not built; the shortcut table is not bound (medium) | CLAUDE.md:551, :552 | Reactions UI is message_row.dart, message_row_parts.dart, message_context_menu.dart and the five emoji picker files; the quick switcher is command_palette.dart and command_palette_items.dart; haptics is design_system/lib/src/app_haptics.dart, which CLAUDE.md:112 itself describes as built; the shortcut table is bound at home_shell.dart:137 `return CallbackShortcuts(`. The same bullet's "History pagination is not built" is accurate: `before` exists at client_messages.dart:14 and 86, and both app call sites (sync_controller.dart:118, channel_screen.dart:88) pass only `limit: 50`. A half-stale bullet is worse than a fully stale one. |
| The invite gate is undeployed; watch the release PR for the cargo-workspace plugin (low) | CLAUDE.md:645 | A live probe of `GET https://slim.npc-server.top/version` returns `{"version":"0.18.0",...,"invite_required":true,"capabilities":["block","report"]}`; the gate is in store/space.rs and threaded through registration at store/sessions.rs:245, 285. Cargo.lock:2437 reads 0.18.0 in step with Cargo.toml:4 across eight server releases since the plugin landed. Both entries state their own closing condition and both are met, one confirmable from outside the repo. |
| `tests/response_contract/**` left unconverted for TestDbGuard cleanup (low) | CLAUDE.md:700 | tests/response_contract/world.rs:38 and :43 now use `crate::support::TestDbGuard`. |
| Three touched files exceed the review budget: sync_controller.dart 316, member_pane.dart 396, channel_screen.dart 583 (low) | CLAUDE.md:394 | Measured: 285, 255 and 374. Two are now under budget and the third shed 209 lines, so the instruction has been carried out. Left standing it either gets obeyed redundantly or teaches the reader that CLAUDE.md's numbers are decorative; scripts/file-budget-allow.txt is already the machine-maintained register. |

### Wrong pointers and wrong numbers

| Claim | Where | Reality |
| --- | --- | --- |
| The permission-gated admin section is `_ModerationSection` in `settings_screen.dart` (medium) | CLAUDE.md:284, CLAUDE.md:411, docs/ROADMAP.md:117 | There is no settings_screen.dart - the screens directory holds personal_settings_screen.dart, space_settings_screen.dart and settings_screen_scaffold.dart - and `_ModerationSection` and "Community management" return nothing from lib/. routes.dart declares `personalSettings` and `spaceSettings`, no `settings`. The live pointers are space_settings_section.dart:63, 79 (where the admin screens are navigated from, and so where the gating lives) and personal_account_sections.dart (account deletion). Split by df0a8ca, #142. CLAUDE.md:411 sits inside a historical PR #50 narrative and can keep the old name if dated. |
| Server 0.10.0; server 0.15.0 across seven releases; client 0.6.0 (medium) | CLAUDE.md:405, docs/ROADMAP.md:53, :329 | Cargo.toml:4 and Cargo.lock:2437 both 0.18.0, .release-please-manifest.json `{"crates/slimm-server": "0.18.0", "client": "0.12.0"}`, and the live instance answers 0.18.0. Not only a number: ROADMAP:53 uses the release count to argue the perf baseline is stale, so that argument is understated by three further releases, and :329 uses the versions to argue distance from 1.0. The fact worth carrying forward is that perf/baselines/0.8.0.json is still the newest baseline. |
| README's Status: "Phase 0 (foundations) is underway ... serves liveness and version endpoints" (medium) | README.md:9-10 | 0.18.0 server, 0.12.0 client, 21 migrations through 0021_space_removals.sql, 62 documented paths, 11 workflows. The README is the only document a drive-by reader sees, and it understates the project by four phases and eighteen minor releases. README:17's layout line ("schema/ OpenAPI + JSON Schema") is wrong in the same way: schema/ holds one OpenAPI file. |
| openapi.yaml `info.version: 0.5.0`, and info.description enumerates the surface (medium) | schema/openapi.yaml:28 | 0.5.0 predates DMs, polls, attachments, voice, emoji and the capability handshake. Parsed: 62 paths, 84 operations, 16 tags declared at :56 and 19 used - `emoji`, `space` and `voice` are declared nowhere. info.description (:29-46) never names voice, custom emoji, the canvas viewport query, pinned messages, attachments, Space settings, member timeouts and removal, or the capability handshake. redocly lint does not flag an undeclared tag and neither contract test inspects tags, and undeclared tags only surface in a rendered document, which is the output nobody generates any more. |
| Account deletion transfers group ownership, including as an App Review argument (medium) | docs/STRATEGY.md:190, :37, :572 | store/account_deletion.rs:56: "Group-ownership transfer is a no-op until an ownership model exists; the current schema has no owner column", and no migration defines one. The real guard is tests/account.rs:228 `the_last_administrator_cannot_strand_a_populated_deployment`. ROADMAP:89 documented this correction on 2026-07-28 and STRATEGY was never updated, so the 5.1.1(v) reasoning still argues from a mechanism that does not exist. ROADMAP:89's own citation is now stale too - it attributes the doc comment to store/sessions.rs. |
| The migrations are "0001 init, 0002 core schema"; src/ is seven files; there are six workflows (low) | CLAUDE.md:602, :603, :733 | 21 migrations; src/ also holds auth.rs, cors.rs, emoji.rs, hub.rs, identity.rs, media.rs, permissions.rs, presence.rs, push.rs, ratelimit.rs, typing.rs and the emoji/, http/, push/, store/ and voice/ directories; there are 11 workflows, and docs/ci.md's glance table documents client-ios-ci, audio-ci, licenses, compose-smoke and push-relay-contract too. Individually cosmetic; together the orientation section a new contributor reads first understates the server by nineteen migrations, eleven modules and five workflows. |
| The e2e run reaches 36 of 59 documented paths (low) | docs/e2e.md:54, CLAUDE.md:417 | A yaml parse counts 62 paths and 84 operations. Low impact because the harness computes the denominator at runtime - e2e.md:52-54 says it is counted from what was really requested "rather than from a list kept by hand" - but the prose snapshot drifts in the direction of overstating coverage, which is the failure the runtime counting exists to prevent. See also the coverage-mechanism finding above: the count is path-level, not operation-level. |
| To upgrade, bump the pinned image tag in docker-compose.yml (server, Caddy, LiveKit or Litestream) (low) | deploy/README.md:243 | The same file at :25 says "`SLIMM_VERSION` is read from `.env`, so pinning never means editing `docker-compose.yml`", and docker-compose.yml:27 is `${SLIMM_VERSION:-latest}` while :50, :80 and :133 hardcode the other three images. A self-hoster following the Upgrading section looks for a server tag, finds a variable expansion, and may hardcode one - defeating the mechanism the same file spent a paragraph explaining. The instruction is correct for the other three services, which is what makes it easy to miss. |

## The three to do first

**1. Gate the tag-push publish path (release.yml:51).**
It is the only finding here where a single command with no failing signal ships an untested binary and an untested signed image to a production deployment that auto-updates.
Everything else in this section costs time; this one costs a release.

**2. Add the app-side reachability gate for `SlimmApi` (client/packages/api).**
Seven unreachable methods is the same defect this project has already shipped three times, and two of them are the whole of the account-recovery owner decision.
It is also the only finding whose fix creates a permanent gate rather than a one-off correction, and the pattern to copy already exists in `tests/response_contract`'s `UNCOVERED`.

**3. Correct schema/README.md, STRATEGY.md's codegen and scanner claims, and CLAUDE.md's four stale lists.**
These are cheap, and they are the findings that multiply.
The nine-specialist report exists specifically to stop re-discovery and half its open list is closed; CLAUDE.md tells contributors that a permission gate lives in a file that was deleted and that four built features are not built; and three documents promise machine guarantees that would stop a reader from checking by hand.
Every hour spent on a problem that no longer exists is charged to this entry.
