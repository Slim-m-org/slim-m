# CI/CD and Release Automation

Status: pre-implementation research, against the finalized server stack (Rust/Axum/Tokio, embedded SQLite, UUIDv7 plus per-scope sequence, schema-first JSON over HTTP/WS).
Scope: repo topology, pipeline structure, conventional-commit enforcement, versioning and GitHub Releases, GHCR multi-arch publishing, a production Dockerfile and compose example that runs voice, Linux artifacts for Fedora, an iOS TestFlight path, supply-chain hardening, and CI caching.

## 1. Repo topology

One monorepo holds the Flutter client and the Rust server: a Cargo workspace, a Dart/Flutter workspace using Dart's native `pub` workspace support, and a `schema/` directory holding the OpenAPI plus JSON Schema source of truth both sides codegen from.
The wire protocol is the tightest coupling in the system: a new WebSocket event kind touches the schema, the generated Rust types, and the generated Dart client together, and version-skew rules are easier to hold when that change lands as one PR against one CI run rather than hand-coordinated across repos.
The relay stays separate: its public surface (register, send, healthz, admin) is small and changes rarely, and coupling its release cadence to Rust plus Flutter CI would only add unrelated flakiness to a service whose design goal is staying minimal.

## 2. Pipeline structure and conventional-commit enforcement

One `ci.yml` runs on every PR: `dorny/paths-filter` (pinned by commit SHA, as is every third-party action below) gates Rust and Flutter jobs by files touched, a schema job regenerates Rust and Dart types from `schema/` and fails on any diff against the committed output, and format/lint/test jobs run per language (`cargo fmt --check`, `clippy -D warnings`, `cargo test --workspace`; `dart format --set-exit-if-changed`, `dart analyze`, `flutter test`).
Because SQLite is embedded, Rust integration tests need no external database container or wait-for-healthy step, a CI simplification the stack decision buys for free.
Conventional Commits are enforced on the PR title, not every commit, via a pinned semantic-PR-title action: squash-merge collapses commit history anyway, so the squash message is what actually becomes the changelog entry, avoiding blocked PRs over messy in-progress commits.
The relay repository runs its own equivalent Go pipeline (`go build`, `go vet`, `go test ./...`, `golangci-lint`, `govulncheck`) independently.

## 3. Versioning and GitHub Releases

Evaluated semantic-release, release-please, cocogitto, and a hand-rolled tag script.
Semantic-release's plugin ecosystem is npm-centric; nothing here is JavaScript, so it would need Node purely as release tooling plus workaround plugins for every non-npm artifact.
Cocogitto is a clean Rust-native option but is tag-driven rather than PR-gated, dropping the deliberate human review point a release should have.
A hand-rolled script is rejected as least-tested, most likely to silently drift from the brief's own mapping.
Decision: `release-please` in manifest mode, with two independently versioned packages inside the monorepo, server and client, plus a third standalone instance in the relay repository.
Independent versioning matters because the two ship on different clocks: the server can release the moment a merge lands, while the client sits behind App Store and TestFlight review.
Each package accumulates conventional commits into a release PR with a real changelog; merging it is the deliberate act that cuts the tag and GitHub Release, matching "GitHub Releases driven versioning" literally.
Pre-1.0, set `bump-minor-pre-major` and `bump-breaking-pre-major` true, overriding release-please's default of freezing the major digit at 0: self-hosters upgrading a running server need a real compatibility signal from day one, which SemVer's 0.x convention would otherwise hide from that audience.
Every artifact job (Docker, Linux packages, TestFlight) triggers off its own package's `release: published` event, so a slow App Store review never blocks a same-day server release.

## 4. GHCR multi-arch publishing

Both images publish `linux/amd64` and `linux/arm64` manifests: "a handful of users" often means a Raspberry Pi or an ARM VPS, so arm64 is not optional.
The server build runs natively on GitHub's free-tier `ubuntu-24.04-arm` runner alongside the amd64 runner, per-arch tags pushed independently and merged with `docker buildx imagetools create`.
Native per-arch builds beat QEMU emulation (5 to 10x slower for Rust) and a cross-compilation toolchain like `cross` or `cargo-zigbuild`, adding a second build system for marginal gain now that free arm64 runners exist.
The Go relay cross-compiles fast enough that one amd64 runner with `docker buildx build --platform linux/amd64,linux/arm64 --push` suffices.

## 5. Production Dockerfile and docker-compose

The server Dockerfile is a musl build whose dependency stage (manifests and empty sources, no `cargo-chef`) is separate from the application stage for cache reuse, `rustls` replaces OpenSSL so the binary has no C TLS dependency, and SQLite links in statically via the bundled feature against the musl target.
The runtime stage is `distroless/static-debian12:nonroot`: non-root, no shell, no package manager, with a `--healthcheck` subcommand baked into the same binary backing the container `HEALTHCHECK`, since a shell-less image has no `curl` to invoke one externally.
Because SQLite is embedded and single-writer, the server owns its data on a named volume directly; there is no separate database container to run or back up, meaningfully lighter than a typical Postgres-backed compose file.
The compose example that actually runs voice adds LiveKit (the already-decided self-hosted SFU), pinned by digest, plus Caddy for automatic TLS.
LiveKit needs explicit UDP port range publishing (or host networking) for its TURN/media path, distinct from the plain TCP proxying Caddy does for the app server; misconfigured SFU networking is the most common self-host failure for any WebRTC service behind Docker, so the example documents it concretely.
Memory limits follow the per-service budgets already set in the media and backend research.

## 6. Linux artifacts for Fedora

Evaluated rpm, AppImage, and flatpak on Fedora's own idiom, not "works everywhere."
Fedora Workstation's default install path is GNOME Software wired to Flathub, and the client already needs xdg-desktop-portal integration for screen capture; flatpak's sandboxing targets that same surface, so its overhead is largely work already owed.
Flatpak is the primary artifact: published to a self-hosted static Flatpak remote from day one, with Flathub submission as a later, non-blocking step so review latency never gates a release.
A plain `.rpm`, built from a hand-written spec rather than a generic packager, ships alongside it for users wanting a native, non-sandboxed install.
AppImage is deferred: it solves cross-distro portability, which matters once distros beyond Fedora are targeted, not this phase's priority; three formats before one is done well is the premature breadth the brief warns against.
Risk: flatpak sandboxing can clip global hotkeys or tray integration; validate the needed portals early.

## 7. iOS TestFlight path

Fastlane `match` stores certificates and profiles in a separate encrypted private git repository rather than raw files in Actions secrets; fastlane `pilot` uploads to TestFlight using an App Store Connect API key, on GitHub-hosted macOS runners.
Every client-package release triggers a TestFlight build, since iOS is a primary testing platform; day-to-day PR CI keeps iOS builds behind manual dispatch, since macOS runners cost roughly ten times a Linux runner.

## 8. Supply-chain hardening

Every third-party action is pinned to a full commit SHA, not a floating tag, closing the mutable-trust-anchor gap a tag pin leaves open.
Every published artifact, images, flatpak, rpm, is signed with `cosign` in keyless mode (Sigstore/Fulcio, bound to the GitHub Actions OIDC identity), plus SLSA provenance via `actions/attest-build-provenance`; no long-lived signing key sits in secrets.
SBOMs come from Buildx's native `--sbom`/`--provenance` flags, not a separate tool, attached as SPDX output to each release.
`cargo audit` and `cargo deny` gate Rust, `osv-scanner` covers Dart, `govulncheck` covers the relay, and Dependabot keeps all three current; a pipeline with no update mechanism just accumulates silent CVE debt.

## 9. Caching

`Swatinem/rust-cache` for the Cargo workspace, `subosito/flutter-action`'s built-in cache plus a `~/.pub-cache` key on `pubspec.lock`, Buildx `type=gha` layer caching (of the Dockerfile's dependency stage), and Go's built-in module cache for the relay.
Bigger or self-hosted runners are deliberately not adopted up front; standard caches should cover a small OSS project's CI budget, and paying for capacity ahead of a measured bottleneck is premature complexity.

## Stack interaction note

No real conflict with the foundational stack surfaced; embedded SQLite simplifies CI (no database container, no readiness race) and the compose file (no separate DB service).
The repository trait's future Postgres implementation does not need its own CI lane until it exists.
One point outside this scope: since the official instance runs the identical published image, its deploy step is just "pull the new tag, restart," better suited to an operations runbook than this pipeline.

## Open questions

Whether the official instance's deploy trigger (an update-checking sidecar versus a manual step gated on release publish) belongs here or in a separate operations document.
