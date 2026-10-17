# Contributing to slim-m

Thanks for helping build a lightweight, self-hostable messenger.

## Provenance: DCO, not a CLA

Every commit must be signed off under the [Developer Certificate of Origin](https://developercertificate.org/):

```
git commit -s
```

This adds a `Signed-off-by` line certifying you wrote or have the right to submit the change.
There is no CLA.

## Commits and releases

Pull request titles follow [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `feat!:` for breaking).
The repository squash-merges, using the PR title as the commit message, and release-please turns those titles into versions and changelogs.
Server and client are versioned independently; a change to `schema/` bumps both.

## Writing docs

In a long Markdown file, put each full sentence on its own line, so a diff shows which sentence changed.
Apply it to what you write or substantially edit; do not reflow a file you are only touching in passing.
Keep docs short, link a decision record rather than repeating it, and use a plain `-` instead of an em dash.

## Definition of done

Run the gates last, on the branch, after `git add`: several of them read only tracked files and report success on an untracked one.
[CLAUDE.md](CLAUDE.md) and `.github/workflows/hygiene.yml` are the authority; [docs/ci.md](docs/ci.md) explains each workflow, and [docs/DEVELOPING.md](docs/DEVELOPING.md) has the commands to run every check locally.
A change is done when every line that applies to it holds.

Every change:

- [ ] The PR title is a conventional commit, and commits are signed off (`git commit -s`).
- [ ] No emoji in client sources and no em dash anywhere; icons are Lucide.
- [ ] A new Rust or Dart source file starts with the SPDX header on its first line.
- [ ] No file passes 500 lines (`scripts/check-file-budget.sh`, which warns at 300), and plain `//` or `#` comments are one line (`scripts/check-comment-cap.sh`).
- [ ] A function takes at most seven positional parameters.
- [ ] A product or architecture decision has a record in `docs/decisions/` under the next free number, with a row in its README and a first heading that starts `# NNNN - ` (`scripts/lib/test_decision_index.py` checks both, and a number used twice).
- [ ] A new workflow has a row in the `docs/ci.md` table that names every trigger it has (`scripts/check-ci-docs.py`, `scripts/lib/test_ci_docs_triggers.py`).
- [ ] The `scripts/lib` unit tests pass: `(cd scripts/lib && python3 -m unittest discover -p 'test_*.py')`.

Server changes:

- [ ] `cargo fmt --all --check`, `cargo clippy --all-targets --all-features -- -D warnings` and the tests pass, with `SQLX_OFFLINE=true`.
  CI runs the suite under `cargo nextest`, which is much faster locally too.
- [ ] A new migration is numbered by the next free version, never edits an applied one, and its checksum is recorded with `scripts/lock-migrations.py`.
  `scripts/check-migration-versions.py` and `scripts/lib/test_migrations_are_immutable.py` check both.
- [ ] After a change to a `query!` or `query_as!`, regenerate `.sqlx/` with `cargo sqlx prepare --workspace -- --all-targets`, and look at `git status` for deleted cache files.
- [ ] A new or changed route has its entry in `schema/openapi.yaml`.
  `tests/openapi_contract.rs` fails on drift, and the additive-only OpenAPI check (`oasdiff breaking`) fails on a breaking change.
- [ ] A new route also has a client binding in `client/packages/api`; the `schema_coverage` and `app_reachability` tests fail without one.
- [ ] Server integration tests use `support::TestDbGuard` and `support::TestDirGuard`, never an unguarded temp path and never `:memory:`.

Client changes:

- [ ] `flutter pub get --enforce-lockfile`, `dart analyze` and `dart format --output=none --set-exit-if-changed .` are clean, and `flutter test` passes in every package that has tests.
- [ ] A user-visible change adds an entry to `client/packages/app/lib/src/whats_new/whats_new_content.dart`; `whats_new_freshness_test.dart` fails after a few releases without one.
- [ ] Errors from the API are shown with the persistent `AppErrorState`, never a SnackBar (`scripts/check-error-surface.py`).
- [ ] `MediaQuery` is read through the scoped accessors (`scripts/check-media-query-scope.py`).
- [ ] `Message` stays a plain DTO at the `data` boundary (`scripts/check-message-dto-boundary.py`).
- [ ] UI follows [docs/design/design-language.md](docs/design/design-language.md), and a surface that differs between desktop and mobile follows [docs/design/desktop-vs-mobile.md](docs/design/desktop-vs-mobile.md), with the rule number in the PR.
- [ ] Removing or renaming a settings control updates `scripts/lib/e2e_labels.py`, because the e2e harness drives the app by those names.
- [ ] A conditional import (`dart.library.js_interop` and the like) is checked with `(cd client/packages/app && flutter build web --release)`, since `dart analyze` does not resolve those branches.
- [ ] Do not commit regenerated goldens made on a local machine; let CI regenerate them.

## Componentization

- The server is a Rust workspace of crates with narrow public surfaces; the client is a Dart pub workspace of small packages.
- Keep files small (a soft 300-line review budget, generated code excluded).
- `cargo fmt` and `cargo clippy -- -D warnings` must pass; the client must pass `dart analyze`.
- No emoji as interface chrome; use Lucide icons. CI enforces this.

## Running the server locally

```
cp .env.example .env
cargo run --bin slimm-server
curl localhost:8080/healthz
```

## Licensing

By contributing you agree that your contribution is licensed under [PolyForm Noncommercial 1.0.0](LICENSE) (see [LICENSING.md](LICENSING.md)), and that you additionally grant NC1107 a perpetual, worldwide, irrevocable, royalty-free license to use, modify and relicense your contribution under any terms, including commercial ones. That second part is what keeps commercial licensing possible without having to track every contributor down later.
