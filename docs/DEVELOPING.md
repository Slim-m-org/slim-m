# Developing slim-m

From a fresh clone to the server, the client and the end-to-end harness running, and how to run every check CI runs before you push.

## What you need

- Rust (the version in `rust-toolchain.toml`), with `sqlx-cli` 0.8 for database work.
- Flutter 3.47 / Dart 3.13 for the client.
- Docker, for LiveKit in the end-to-end harness and for the server image.
- Python 3 for the scripts under `scripts/`, Node for the commit-message lint.
- Android builds need a Temurin 21 JDK; iOS builds need macOS and Xcode and are otherwise checked in CI.

## Layout

- `crates/slimm-server/`: the Rust server (one process, HTTP and WebSocket, SQLite).
- `client/`: the Flutter workspace, layered `api` -> `data` -> `design_system` / `platform` / `rtc` / `voice_canvas` -> `app`.
- `schema/openapi.yaml`: the wire contract; it changes with every route change.
- `scripts/`: hygiene gates, release tooling, the e2e harness (`scripts/e2e.sh`, `scripts/lib/e2e_*`) and seed and load tools.
- `docs/`: see [docs/README.md](README.md).

## Server

```bash
cp .env.example .env
cargo run --bin slimm-server
curl localhost:8080/healthz
```

Checks, as CI runs them (the repo builds with the committed `.sqlx/` cache):

```bash
SQLX_OFFLINE=true cargo fmt --all --check
SQLX_OFFLINE=true cargo clippy --all-targets --all-features -- -D warnings
SQLX_OFFLINE=true cargo test --all

# one test file, then one case in it
SQLX_OFFLINE=true cargo test --test channels
SQLX_OFFLINE=true cargo test --test channels -- manager_can_rename_a_channel --exact --nocapture
```

After changing a `query!` or `query_as!`, refresh the offline cache, including test queries:

```bash
export DATABASE_URL="sqlite:////tmp/slimm-dev.db"
(cd crates/slimm-server && sqlx database create && sqlx migrate run --source migrations)
cargo sqlx prepare --workspace -- --all-targets
```

A migration that has reached `main` is never edited, renamed or renumbered; fix mistakes with a new one, and run `python3 scripts/lock-migrations.py` after adding one.

## Client

```bash
cd client
flutter pub get --enforce-lockfile
dart analyze
dart format --output=none --set-exit-if-changed .
```

`flutter test` runs per package, the way CI loops over them:

```bash
cd client
for d in . packages/*/; do [ -d "${d%/}/test" ] && (cd "${d%/}" && flutter test); done

# one file, or one case by name
(cd packages/app && flutter test test/api_failure_test.dart)
(cd packages/app && flutter test test/api_failure_test.dart --plain-name '<part of the test name>')
```

After touching a conditional import, also build for the web, since dart2js resolves branches the analyzer does not:

```bash
(cd client/packages/app && flutter build web --release)
```

Drift's generated code is committed; regenerate it rather than editing it:

```bash
(cd client/packages/data && dart run build_runner build --delete-conflicting-outputs)
```

## Looking at the UI

- `scripts/ui-snapshots.sh` renders the real shell at every shipped resolution into `client/packages/app/build/ui-snapshots`.
- `scripts/ui-capture.sh` runs the per-surface snapshot harnesses; a new harness needs a `JOBS` line there.
- Snapshot tests write PNGs only with `SLIMM_UI_SNAPSHOTS=1`; otherwise they just check the layout.

## End to end

```bash
scripts/e2e.sh --keep                    # real LiveKit, the server and two browsers
E2E_ONLY="reaction" scripts/e2e.sh       # one scenario, or several split by |
E2E_REBUILD=1 scripts/e2e.sh             # after a client change, or it serves the old web build
```

See [e2e.md](e2e.md) for how the harness finds controls and what each scenario proves.

## Load tests and profiling

```bash
scripts/load-run.sh fanout -e LISTENERS=500 -e SENDERS=10   # k6 in Docker against a throwaway local server
scripts/load-run.sh --profile http_mix                      # the same, under samply
```

It refuses any target that is not loopback, so it can never touch the live deployment.
See [../perf/load/README.md](../perf/load/README.md).

## The gates CI runs, locally

Each of these fails a pull request in `hygiene.yml`, and each has a local script.
Git only sees tracked files, so `git add` new files before trusting a run.

```bash
scripts/check-file-budget.sh                 # 300-line review budget, fails 60 past the 500 ceiling
scripts/check-comment-cap.sh                 # plain comments are one line; no file may gain a run
python3 scripts/check-error-surface.py       # API failures use AppErrorState, never a SnackBar
python3 scripts/check-migration-versions.py  # duplicate or edited migrations
python3 scripts/check-media-query-scope.py   # scoped MediaQuery accessors only
python3 scripts/check-message-dto-boundary.py
python3 scripts/check-ci-docs.py             # every workflow has a row in docs/ci.md
(cd scripts/lib && python3 -m unittest discover -p 'test_*.py')   # the harness and workflow-shape gates
(cd scripts/commit-lint && npm ci && node check-parses.mjs)       # PR title and commit bodies parse for release-please
```

Read the unittest run's `OK` or `FAILED` summary line, not its last line: some tests print `FAIL` as part of their expected output.
`actionlint` and `shellcheck` run pinned by image digest in CI; see [ci.md](ci.md) for the digests.

## Conventions

- Branch, pull request, squash merge to `main`, with a conventional-commit title (`feat:`, `fix:`, `chore:` and so on) so release-please can classify it.
- Commit with `git commit -s`.
- Plain comments are one line and say why, never how; durable reasoning goes in a decision record or a doc.
- Keep files under 300 lines where practical and 500 as the budget.
- `main` deploys the server continuously, so treat server changes as production changes.

More: [CONTRIBUTING.md](../CONTRIBUTING.md) for the definition of done, [ci.md](ci.md) for every workflow, [RELEASING.md](RELEASING.md) for releases.
