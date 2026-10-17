# slim-m

A lightweight, cross-platform, open source messaging platform with optional self-hosting.

`slim-m` is a working name; the final name is undecided.

## Status

Phases 0 through 4 (foundations, server and protocol core, client shell, push notifications, voice and screen share) are complete, and later phases are substantially underway: a first Voice Canvas write slice, the admin and moderation screens, the client capability handshake, and part of the motion, accessibility and audio-design polish pass have all shipped.
Both components ship signed release artifacts and run on a live self-hosted instance; the `.release-please-manifest.*.json` files carry the current versions rather than this paragraph, which went stale by forty releases the last time it named them.
Later work includes bots, incoming webhooks, modules and the Dock, two-factor authentication and signed self-update for the desktop apps.
See `client/CHANGELOG.md` and `crates/slimm-server/CHANGELOG.md` for what has shipped, the [decision records](docs/decisions/README.md) for why, and the [roadmap](docs/ROADMAP.md) for phases and exit criteria.

## Layout

```
crates/slimm-server   Rust home server (Axum + embedded SQLite via sqlx)
schema/               OpenAPI (openapi.yaml), the single source of record for the wire protocol - hand-written types on both sides, not generated from it
client/               Flutter client (Dart pub workspace of small packages)
docker/               Container images for the server and the web client
docker-compose.yml    Self-host example (voice is the docker-compose.voice.yml overlay)
deploy/               Caddy config and the self-hosting walkthrough
packaging/            Linux, Windows, flatpak and rpm packaging
scripts/              Hygiene gates, backup and restore, release helpers
perf/                 Performance model
docs/                 Brief, strategy, roadmap, decisions, and research
```

The push relay is a separate repository, adapted from [check-in-relay](https://github.com/NC1107/check-in-relay).

## Installing the app

If you are joining someone's space rather than running one, see **[docs/INSTALL.md](docs/INSTALL.md)** - one section per platform, including the security warnings Windows, macOS and Android will show you and what to click.
Ask whoever runs the space for its address and an invite code before you start.

If the space offers a web client, opening that address in a browser needs no install at all and is the easiest route.

## Self-hosting a server

The full walkthrough is [deploy/README.md](deploy/README.md).
[docs/OPERATING.md](docs/OPERATING.md) lists every setting and covers two-factor, modules, webhooks, bots and updating, and [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) is organised by symptom.
Text chat needs one DNS record and two values in a `.env`; voice and screen share are an overlay you add when you want them.

## Running the server

```bash
cp .env.example .env
cargo run --bin slimm-server
curl localhost:8080/healthz     # -> ok
curl localhost:8080/version     # -> {"name":"slim-m",...}
# optional: SLIMM_BUILD_ID=$(git rev-parse --short HEAD) cargo run adds a build_id to /version
```

## Documents

- API reference: [schema/openapi.yaml](schema/openapi.yaml) is the source of record; nothing renders it automatically (GitHub has no built-in OpenAPI viewer and building one into a CI artifact nobody downloads was not worth a job), so build a browsable copy locally with `npx @redocly/cli build-docs schema/openapi.yaml -o /tmp/api.html`
- [Brief](docs/BRIEF.md), [strategy](docs/STRATEGY.md), [roadmap](docs/ROADMAP.md)
- [docs/README.md](docs/README.md): where every document is
- [Decisions of record](docs/decisions/)
- [Licensing](LICENSING.md) (PolyForm Noncommercial, whole repo), [contributing](CONTRIBUTING.md)

## License

[PolyForm Noncommercial 1.0.0](LICENSE), one license for the whole repository; see [LICENSING.md](LICENSING.md).

Free for noncommercial use: personal, hobby, educational, research, nonprofit, and all that.
You can fork it, change it and redistribute it, you just can't sell it or use it commercially without asking first.
If you want to use it commercially, open an issue and ask.

## For contributors

[docs/DEVELOPING.md](docs/DEVELOPING.md) goes from a fresh clone to everything running, and runs every CI check locally.
[CONTRIBUTING.md](CONTRIBUTING.md) has the definition of done.
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) is a ten minute tour of the code.
[docs/RELEASING.md](docs/RELEASING.md) is the release runbook, and [docs/CHANGING-CI.md](docs/CHANGING-CI.md) is what to know before editing a workflow.
