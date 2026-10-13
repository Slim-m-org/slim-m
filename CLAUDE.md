# slim-m

Durable project context for Claude Code. Keep this file short; detailed history and reasoning belong in `docs/`.

## Project

slim-m is a lightweight, self-hostable Discord-style platform for text, voice, screen sharing, and a collaborative Voice Canvas.

- Client: Flutter/Dart workspace under `client/`
- Server: Rust + Axum under `crates/slimm-server/`
- Push relay: stateless Go service
- Media: self-hosted LiveKit
- Database: SQLite via sqlx, WAL mode
- Wire protocol: schema-first JSON in `schema/openapi.yaml`
- Name is temporary; final product name is chosen before 1.0

Read first when starting substantial work:
1. `docs/BRIEF.md`
2. `docs/STRATEGY.md`
3. `docs/ROADMAP.md`
4. `docs/decisions/`
5. `docs/OPEN-QUESTIONS.md` when device/account/owner confirmation matters

## Task tracking (Planka)

Planka is the single source of truth for tasks and backlog: `https://planka.npc-server.top`, project `slim-m`, board `Backlog & Delivery`. Drive it through the `planka` MCP server (`mcp__planka__*` tools, configured in the user MCP config). The MCP loads at session start; if its tools are absent, the session predates the config and needs a restart.

Lists are a simple flow: **Backlog** (validated, unscheduled) -> **Ready** (scoped enough to start from the card alone) -> **In Progress** -> **In Review** (PR open) -> **Done** (merged).

- Pull the next task from **Ready**. Move its card to **In Progress** when you start, **In Review** when the PR is open (put the PR link in the card), **Done** when it merges. Keep the board current; do not let it drift.
- Every card is self-contained: the problem (with the owner's own words where they exist), the relevant files, what already exists so nobody rebuilds it, acceptance criteria, and a gates reminder - enough that a subagent given only the ticket knows what to do.
- Finding new work: check the live deployment's backlog channel first (see the `prod-account` memory), then for each item **validate it is real and not already shipped** - grep the code and check merged PRs - before creating a card. Many backlog asks are already done; do not re-file them.
- Labels: area (`client`/`server`), kind (`feature`/`bug`/`perf`/`a11y`/`ui/ux`/`chore`), and `mobile` where a task is phone-specific.

## Architecture and product decisions

- Server is a single process with HTTP + WebSocket.
- SQLite is the current database; the storage layer is intended to allow a later Postgres swap.
- Durable writes use idempotent REST requests keyed by UUIDv7.
- WebSocket is for server fan-out and ephemeral signals.
- Identity is UUIDv7; ordering is a per-channel/stream monotonic `Seq`.
- OpenAPI is the wire contract, but Rust DTOs and Dart models are hand-written.
- v1 uses transport encryption only; E2EE DM infrastructure is pre-wired for later.
- One deployment is one community. v1 DMs are same-deployment only.
- Account recovery is admin-issued one-time reset codes; no email recovery.
- No automated content/media scanning. Moderation is manual reporting, blocking, and moderation tooling.
- Voice Canvas is a bounded large world, not literally infinite.
- Presence can be hidden/offline.
- Read receipts are deferred.
- UI uses Lucide icons, never emoji as interface chrome.
- Follow the design system in `docs/design/design-language.md`; read the relevant decision record before changing locked design tokens.
- Any UI that differs between desktop and mobile follows `docs/design/desktop-vs-mobile.md`: layout responds to window width, never to platform; pick the surface with its decision guide and note the rule number in the PR.

## Code map

Things that only become visible after reading several files.

Server (`crates/slimm-server/src/`):

- `main.rs` is a thin wrapper; everything lives in the library so integration tests can drive the real router.
- `lib.rs::run` wires `AppState` (store, auth, hub, limiter, push, voice, media, gifs, link_previews, dock, code_runner) and spawns the background sweeps: expired tokens, orphaned attachments, canvas ops, forward backfill, stale calls, ring, message retention.
- `http/` and `store/` are both split one module per feature and mirror each other; a new feature usually means a matching pair plus a route in `http.rs` and an entry in `schema/openapi.yaml`.
- `store.rs` keeps methods inherent on `Store` rather than behind a repository trait; that trait arrives when Postgres actually needs it.
- `hub.rs` is two class-based broadcast channels (durable and ephemeral), not a per-scope router. Fan-out order across concurrent writers is best-effort, so clients apply events strictly by per-scope `seq`. A subscriber that lags past `CHANNEL_CAPACITY` is dropped, and the client resyncs over REST.

Client (`client/packages/`), layered bottom-up:

- `api` (wire types and transport, no Flutter) -> `data` (drift local store and sync) -> feature packages (`design_system`, `platform`, `rtc`, `voice_canvas`) -> `app` (screens, routing, providers).
- `app` uses riverpod for state and go_router for routing; `app/lib/src/` is grouped by `screens/`, `widgets/`, `providers/`, `routing/`.
- `data` commits drift's generated `database.g.dart`; regenerate it rather than hand-editing.

## Critical rules

### Migrations

**A migration that has reached `main` is immutable.**

sqlx validates applied migrations by version and checksum. Never edit, rename, delete, or renumber an applied migration. Fix mistakes with a new migration.

`scripts/check-migration-versions.py` is the hygiene gate for duplicate versions and mutations.
A new migration also needs `scripts/lock-migrations.py` run, because the lockfile gate lives in `scripts/lib`.

This matters especially because **main is continuously deployed**: `main-builds.yml` can publish `latest`, and Watchtower deploys it to the live instance. A merge to main can therefore be a production deploy even without a release.

### sqlx offline cache

The repository commits `.sqlx/` and CI/Docker build with `SQLX_OFFLINE=true`.

After changing `query!` / `query_as!` queries:

```bash
export DATABASE_URL="sqlite:////tmp/slimm-dev.db"
(cd crates/slimm-server && sqlx database create && sqlx migrate run --source migrations)
cargo build
cargo sqlx prepare --workspace -- --all-targets
```

`--all-targets` is required or test queries can disappear from `.sqlx/`.

Check `git status` for unexpected `.sqlx/` deletions before committing.

### API schema

`schema/openapi.yaml` must change with route changes.

`crates/slimm-server/tests/openapi_contract.rs` compares documented routes with the actual Axum router and fails CI when they drift.

### Source-reading gates

Tests that inspect source text must strip comments/strings before looking for code. Do not write raw substring or brace-counting checks that comments can fool.

When adding a source-reading gate, look at the existing shared scrubbers/helpers first.

### Testing and async UI captures

Do not assume a green test means the real UI state was rendered. Snapshot/capture tests have explicit settling and mid-flight checks.

`SLIMM_UI_SNAPSHOTS` capture paths can use different paint/pump behavior than ordinary tests. Preserve the existing `expectSettled`/capture helpers rather than adding arbitrary pumps.

### Local test resources

Use the existing test DB/media helpers and guards. Do not create unguarded temp DBs or media roots.

Server integration tests declare `mod support;` and take their paths from `support::TestDbGuard::new(prefix)` and `support::TestDirGuard::new(prefix)`, which clean up on drop.

Never use `:memory:` for tests that depend on the multi-connection SQLite pool.

### Hygiene gates

`hygiene.yml` fails a PR on any of these, and each has a local script so it need not be discovered in CI:

- `scripts/check-file-budget.sh` - warns at 300 lines, warns past 500 (or an allowlisted ceiling) and fails only more than 60 lines past it. `file-budget-allow.txt` holds the exceptions.
- `scripts/check-comment-cap.sh` - ratchets the one-line plain-comment cap; a file may not gain a new run. `comment-cap-allow.txt` holds the pre-existing ones at their count.
- `scripts/check-error-surface.py` - no API failure may be caught and surfaced with a SnackBar; use the persistent `AppErrorState`. This regressed back three times.
- `scripts/check-migration-versions.py` - duplicate or mutated migrations.
- `scripts/check-media-query-scope.py` - no unscoped `MediaQuery.of(context)` in `client/**/*.dart` outside `media-query-of-allow.txt`; use the scoped accessor (`MediaQuery.sizeOf`, `MediaQuery.viewInsetsOf`, ...) instead.
- `scripts/lib/test_release_required_checks_*.py` - the two structural gates on `release.yml`'s `required_checks`: every name is a real job name, and the one it names can reach a release commit.
- `scripts/lib/test_ci_docs_triggers.py` - a workflow's `docs/ci.md` row mentions every trigger kind it has. `check-ci-docs.py` only checks the row exists; this checks it is not lying about when the workflow runs.
  All three run in the `scripts/lib` unittest suite, not as their own steps.
- `scripts/commit-lint` (`npm ci && node check-parses.mjs`) - the PR title parses, and no commit body crashes release-please's parser. A body that crashes it is dropped from the changelog silently.
- `scripts/check-ci-docs.py` - every workflow has a row in `docs/ci.md`'s table. It checks the row exists, never what the row says.
- `actionlint` over every workflow, which also shellchecks the inline `run:` blocks, and `shellcheck` over every tracked `*.sh`. Both are pinned by image digest, because the runner's preinstalled shellcheck and the `stable` image are different versions that disagree; verify locally with the pinned digest, not with whatever `shellcheck` is on PATH. Both were green when they landed, so either failing means the change under review introduced it.
- `scripts/check-message-dto-boundary.py` - `data.dart` exports `Message` as a plain DTO, never a drift row.
- Inline in the workflow: no emoji in `client/` Dart/YAML/ARB sources, an SPDX header on the first line of every `crates/**/*.rs` and Dart source file, orientation locked on phones only, the iOS Info.plist/broadcast-extension/notification-extension wiring checks, and unit tests for the e2e harness's own scenario logic.

## Local environment

Primary development target: Fedora 44 + KDE Plasma Wayland.

Available:
- Rust/cargo 1.94
- Go 1.26
- Flutter 3.47.0 / Dart 3.13.0
- Docker
- Node
- authenticated `gh`
- `sqlx-cli` 0.8

Android builds require the user-local Temurin 21 JDK:

`~/.local/jdk/jdk-21.0.12+8`

iOS requires macOS/Xcode and is validated through CI/TestFlight.

Golden files should be regenerated in CI because engine/font rendering can differ locally.

## Common commands

Server:

```bash
cp .env.example .env
cargo run --bin slimm-server
curl localhost:8080/healthz
curl localhost:8080/version
```

Server checks, and one test at a time:

```bash
SQLX_OFFLINE=true cargo fmt --all --check
SQLX_OFFLINE=true cargo clippy --all-targets --all-features -- -D warnings
SQLX_OFFLINE=true cargo test --all

# one integration test file, then one case inside it
SQLX_OFFLINE=true cargo test --test channels
SQLX_OFFLINE=true cargo test --test channels -- manager_can_rename_a_channel --exact --nocapture
```

Client:

```bash
cd client
flutter pub get --enforce-lockfile                  # drop the flag when adding a dependency
dart analyze                                        # workspace-wide
dart format --output=none --set-exit-if-changed .   # workspace-wide
```

`flutter test` is per package, not workspace-wide. CI loops over every package that has a `test/` directory, so match that when checking a change:

```bash
cd client
for d in . packages/*/; do [ -d "${d%/}/test" ] && (cd "${d%/}" && flutter test); done

# one file, or one case by its test name
(cd packages/app && flutter test test/api_failure_test.dart)
(cd packages/app && flutter test test/api_failure_test.dart --plain-name '<substring of the test name>')
```

Goldens run inside those suites rather than a job of their own, and should be regenerated in CI.

After touching a conditional import (`dart.library.js_interop` and friends), run `(cd client/packages/app && flutter build web --release)`. dart2js resolves branches that `dart analyze` never does, and main once shipped a web build that could not compile with analyze, format, and every test green.

Other loops:

```bash
(cd client/packages/data && dart run build_runner build --delete-conflicting-outputs)  # drift codegen
scripts/ui-snapshots.sh                  # real shell at every shipped resolution -> client/packages/app/build/ui-snapshots
scripts/e2e.sh --keep                    # real LiveKit + server + two browsers; --keep leaves it up
(cd scripts/lib && python3 -m unittest discover -p 'test_*.py')   # the e2e harness's own logic
npx @redocly/cli build-docs schema/openapi.yaml -o /tmp/api.html  # browsable API reference
docker build -f docker/server.Dockerfile -t slimm-server:dev .
```

## Repository layout

```text
crates/slimm-server/  Rust server
client/               Flutter/Dart workspace
schema/openapi.yaml   API contract
docker/               server image
docker-compose.yml    self-host example
deploy/               Caddy + operator config
perf/                 performance model
.sqlx/                committed sqlx offline cache
docs/                 project docs, decisions, reports, CI, research
```

## CI / release

See `docs/ci.md` for the authoritative workflow list and behavior.

Important conventions:

- Multi-arch images are built natively per architecture, then merged by digest and cosign keyless-signed.
- Do not reintroduce QEMU/cross compilation for the server images.
- Keep pinned third-party actions pinned where the workflow requires exact versions.
- `release-please` uses a standing release PR. Merging it creates the release/tag and artifacts.
- Client releases use the same release-please flow under `client/`.
- `e2e` is advisory, not a required PR check. A sustained red streak is watched separately.
- `main-builds.yml` can deploy unreleased `main` server builds, so treat server changes as production-sensitive.

## Contribution conventions

- Branch -> PR -> squash merge to `main`.
- Use conventional-commit PR titles/bodies so release-please can classify the change.
- Commit with `git commit -s`.
- Never add AI attribution or co-author trailers.
- Never use the em dash character; use `-`.
- No emoji as UI chrome.
- Keep human-authored files under 300 lines where practical, and 500 as the budget. A file a little past it gets a Planka card to split it, not a split mid-feature; split in the change only when it is clearly unreasonable.
- Plain comments (`//`, `#`) are one line max. Put durable reasoning in doc comments, `docs/`, or decision records.
- Keep functions at 7 or fewer positional parameters; use a struct/parameter object beyond that. Named Dart widget/data-class parameters are fine.
- Published material under Nick's name must follow `~/.claude/Voice.md`: plain, hedged, anti-hype, lowercase product names, no emoji/exclamation points.
- Prefer haiku for trivial operations, sonnet for normal coding/analysis, opus only for hard reasoning/orchestration. Never use fable for engineering.

## Known owner-only / unresolved items

Do not silently decide these:

- Real Android end-to-end background push test.
- Reviewer protection for `release` and `testflight` GitHub Environments.
- `RELEASE_PLEASE_TOKEN` is set, so release PRs are authored by the owner and run their full checks. It must stay set and unexpired: without it they fall back to `app/github-actions`, GitHub holds those runs at `action_required`, and a release PR shows `UNSTABLE` with only SonarCloud reporting.
- Optional GPG signing secret for Linux client checksums.
- Whether to keep release-please's auto-PR flow or switch to manual tag releases.
- Play internal tester management requires the owner; there is no Play Developer API credential available.
- Device-specific iOS/Android behavior that has not been tested on real hardware.
- Product/design decisions not already captured in `docs/decisions/`.

Wayland screen sharing is reported working by the owner; an older research note treated it as blocked, so do not plan around that old conclusion without reproducing the issue.

## Where detailed history belongs

Do not turn this file into a chronological changelog.

For prior investigations, bug causes, security reviews, UI review findings, migration incidents, release incidents, and detailed reasoning, search the relevant `docs/` material and decision records. This file should retain only durable rules, current architecture, important traps, and genuinely unresolved work.

Useful references:
- `docs/OPEN-QUESTIONS.md` - things requiring owner/device/account confirmation
- `docs/BACKLOG.md` - accepted/parked work
- `docs/os_backlog/README.md` - platform-specific known issues
- `docs/design/design-language.md` - visual system
- `docs/design/desktop-vs-mobile.md` - responsive layout and which-surface rules (width, not platform)
- `docs/decisions/` - architectural/product decisions
- `docs/research/README.md` - research index and superseded findings
- `docs/ci.md` - CI details
