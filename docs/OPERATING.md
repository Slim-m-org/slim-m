<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# Operating a slim-m server

This is the reference for the person who runs a deployment.
[deploy/README.md](../deploy/README.md) is the walkthrough for standing one up, and this page covers what it does not: every setting, two-factor from the operator's side, module sources, webhooks, bots and updating.
When something is not working, [TROUBLESHOOTING.md](TROUBLESHOOTING.md) is organised by symptom.

## Every server setting

The server reads `SLIMM_`-prefixed environment variables (`crates/slimm-server/src/config.rs`), plus three more read elsewhere.
There are two example files and they are for different things.
The root `.env.example` is for the server binary run directly.
`deploy/.env.example` is for the compose deployment, which sets only some of the server's variables and a few of its own (`SLIMM_API_DOMAIN`, `SLIMM_VERSION`, `ACME_EMAIL`, the `LIVEKIT_*` and `LITESTREAM_*` values) that the server never reads.

The last column says whether `docker-compose.yml` (plus `docker-compose.voice.yml` for voice) passes the variable into the server container.
A variable marked "no" is not dropped by the server, but a `.env` value does nothing for it under compose.
To set one of those you need a compose override file that adds it to the `server` service's `environment`.

| Variable | Default | What it does | Compose passes it |
| --- | --- | --- | --- |
| `SLIMM_PORT` | `8080` | TCP port for HTTP and WebSocket. | no, the image sets 8080 |
| `SLIMM_DATABASE_PATH` | `data/slimm.db` | The SQLite file. | no, the image sets `/data/slimm.db` |
| `SLIMM_DATA_KEY_ALLOW_NEW` | unset | Set to `1` to let a server with sealed two-factor secrets and no key start with a fresh one. Only after every factor was cleared; see [The data key](#the-data-key). | no |
| `SLIMM_DATA_KEY` | unset | Base64 of 32 random bytes: the key that seals two-factor secrets. Unset, the server keeps the key in `slimm-data.key` beside the database, created on first start with mode 0600. See [The data key](#the-data-key). | no |
| `SLIMM_ATTACHMENTS_DIR` | `data/media` | Where attachment and avatar bytes live, beside the database. | no, the image sets `/data/media` |
| `SLIMM_ATTACHMENT_MAX_BYTES` | `1073741824` (1 GiB) | Largest single upload. Over it is a 413. | no |
| `SLIMM_MAX_TOTAL_ATTACHMENT_BYTES` | unset, no ceiling | Most bytes held in attachments and custom emoji together. Over it is a 507. Avatars are outside it. | yes, example sets 2 GiB |
| `SLIMM_HASH_CONCURRENCY` | `4` | How many Argon2id password hashes run at once, about 19 MiB each while running. | no |
| `SLIMM_LOG` | `info` | Log filter in tracing `EnvFilter` syntax. | yes |
| `SLIMM_TRUST_PROXY_HOPS` | `0` | How many reverse proxies in front of the server may be believed about a caller's address, for rate limiting. | yes, defaults to 1 for Caddy |
| `SLIMM_CORS_ALLOWED_ORIGINS` | unset, no CORS | Comma-separated browser origins allowed cross-origin. `*` and malformed entries stop startup. | yes |
| `SLIMM_MIN_CLIENT_VERSION` | unset, no floor | Oldest client version still served, as `X.Y.Z`. Older clients are stopped and offered an update. Empty is read as unset. | yes |
| `SLIMM_DIRECT_ADDRESSES` | unset | Comma-separated `host:port` where native clients on your own network reach the same TLS endpoint directly, for example `10.0.0.100:443`, so they skip Cloudflare or another proxy. Clients verify the certificate against the public hostname, and only dial a private or loopback IP literal on the server's own port. Served to signed-in clients at `GET /direct-route`, never in the unauthenticated `/version`. | yes |
| `SLIMM_MODULE_LAN_DENY` | unset | Comma-separated IPs or CIDRs (for example `10.0.0.50, 192.168.1.0/24`) that a module with the Private network approval may never reach. Always refused as well: this server's own addresses, the hosts in `SLIMM_DIRECT_ADDRESSES` (the docker host's LAN address), and every docker bridge network the container can see. Malformed entries are logged and ignored. | no |
| `SLIMM_LINK_PREVIEWS` | `false` | Unfurl pasted links into preview cards. Makes the server fetch member-supplied URLs behind an SSRF guard (decision 0019). | yes |
| `SLIMM_GIF_PROVIDER` | unset | `tenor` or `klipy`. Set it with the key or neither. An unrecognised value stops startup. | yes |
| `SLIMM_GIF_API_KEY` | unset | Your key for that provider. | yes |
| `SLIMM_LIVEKIT_URL` | unset | The address clients can reach LiveKit on, for example `wss://livekit.example.com`. | voice overlay only |
| `SLIMM_LIVEKIT_API_KEY` | unset | The key LiveKit knows this deployment by. | voice overlay only |
| `SLIMM_LIVEKIT_API_SECRET` | unset | The matching secret. Set all three LiveKit variables or none; with none, every voice route answers 501. | voice overlay only |
| `SLIMM_LIVEKIT_SERVICE_URL` | derived from `SLIMM_LIVEKIT_URL` | Where this server reaches LiveKit for roster and kick calls, for example `http://livekit:7880` on the compose network. Set it when `SLIMM_LIVEKIT_URL` goes out through a proxy such as Cloudflare, which adds roughly 100 ms to every call. | voice overlay only |
| `SLIMM_PUSH_RELAY_URL` | unset | Base URL of the push relay. `http://` is refused unless it is loopback or private-range. | no |
| `SLIMM_PUSH_RELAY_KEY` | unset | Bearer key sent to the relay. Set both push variables or neither; with neither, push is off and the server says so once at startup. | no |
| `SLIMM_ADDONS_REPO` | `Slim-m-org/slim-addons` | The `owner/repo` the Dock reads as the official module source, always from `raw.githubusercontent.com`. The older `NC1107/slim-addons` is tried too. | no |
| `SLIMM_CODE_RUNNER_URL` | unset | Base URL of a Piston instance you run. Unset means no Run button on code blocks. | no |
| `SLIMM_MEMORY_LIMIT_BYTES` | the cgroup limit | Overrides the memory ceiling the server refuses new WebSocket connections near. With no limit found, connections are always admitted. | no |
| `SLIMM_BUILD_ID` | unset | Identifier `/version` reports, 1 to 12 letters or digits. Read when the server is compiled, so it does nothing on a running one. | not applicable |

A few things follow from the "no" entries.
Push notifications cannot be turned on through `.env` under the shipped compose file, because it does not pass the relay pair; that is a gap in the example, not a design choice, and a compose override closes it.
The same holds for the module repository, the code runner and the memory override.

## Ports and voice off the LAN

Text chat needs only 80 and 443 reaching Caddy.
Voice and screen share need more, and Docker publishing a port does not open it on your router or cloud firewall.
For a call to carry media from outside your network, forward all of these to the host:

- 7881/tcp, the fallback for a client that cannot send UDP.
- 50000-50100/udp, the call media range.
- 30000-30100/udp, TURN's relay ports, a separate block.
- 3478/udp, STUN and TURN.

Each pair follows its `LIVEKIT_*` variable in `.env`, so change the variable if something else holds the port.
Leaving the TURN relay range closed is worse than having no TURN: relay candidates are advertised and time out, so calls hang instead of failing fast.
TURN over TLS on 5349 is not configured.
No compose file configures it, and enabling it is a manual job described in [deploy/README.md](../deploy/README.md#turntls-and-why-it-is-not-on-443).
A client on a network that allows only outbound 443 therefore cannot use TURN to get out.
The symptom of a missing forward is a call that joins and then carries no media; see [TROUBLESHOOTING.md](TROUBLESHOOTING.md#voice-does-not-connect-off-the-lan).

## Two-factor authentication

Members can turn on TOTP (an authenticator app) from their own settings, under Two-factor authentication.
Enrolment is two steps: the server issues a secret, and only a confirmed code switches the factor on and returns ten one-time recovery codes.
The operator sets the deployment policy in Space settings, under Invites, Two-factor authentication.

| Policy | Effect |
| --- | --- |
| Nobody new can turn it on (`off`) | New enrolments are refused. A factor someone already enabled is still enforced. |
| Anyone who wants to (`optional`, the default) | Members choose. |
| Expected of admins and moderators (`required_for_elevated`) | Reported to the client only. The server does not enforce it yet (decision 0048). |

Five wrong codes in a row lock the factor for 15 minutes.
A code works once, within 30 seconds either side of the current step.
The secret has to be stored so the server can recompute codes, so it is encrypted with a key that does not live in the database (see below).
A copy of the database file alone, a Litestream replica included, cannot generate codes for enrolled accounts.

### The data key

The key is read from `SLIMM_DATA_KEY` when that is set, otherwise from `slimm-data.key` next to the database file.
The file is created the first time the server starts, with mode 0600, and holds 32 random bytes as base64.
Secrets stored in the clear by an earlier version are encrypted the next time the server starts, with no action on your side.
The server refuses to start when sealed secrets exist and neither `SLIMM_DATA_KEY` nor the key file is present, because a fresh key would silently lock out every member with two-factor on.
Restore the key, or clear the factors (`slimm-server clear-totp <username>`) and start once with `SLIMM_DATA_KEY_ALLOW_NEW=1`.

**Rolling back.**
After the first start on this version every two-factor secret is sealed, so an older server image cannot read them and two-factor sign-in fails for those members.
To go back, either clear the factor for each affected member with `slimm-server clear-totp <username>` and let them enrol again, or restore a database backup taken before the upgrade (which holds the secrets in the clear).

**Back the key up, and back it up apart from the database.**
Litestream and `scripts/backup.py` carry the database, not this file, which is the point of keeping them separate.
A database restored without its key cannot open the stored two-factor secrets, so those members cannot complete a two-factor sign-in.
The server logs an error at start-up when that is the case.
Recovery is the same as for a lost authenticator: an administrator or `slimm-server clear-totp <username>` clears the factor and the member enrols again.
With the compose deployment the file lives in the `slimm_data` volume at `/data/slimm-data.key`; set `SLIMM_DATA_KEY` in `.env` instead if you would rather keep the key with your other secrets.
Generate one with `openssl rand -base64 32`.

## Signing in

A wrong password counts against the account as well as against the caller's address, so a guesser who rotates addresses is still slowed.
After 10 wrong passwords in a row each further one doubles a delay that starts at 15 seconds and never passes 15 minutes.
While the delay runs, sign-in for that account answers 401 like any wrong password, even with the right one, and takes as long as one that was checked, so it does not reveal whether the account exists.
A second count per account, across every address, allows 30 wrong passwords before the account itself is slowed, with the same doubling delay capped at 5 minutes.
A correct password clears both counts, and so does 15 minutes without a wrong one.
If `SLIMM_TRUST_PROXY_HOPS` looks wrong for the traffic, the server logs one warning the first time it sees it.
The delay is capped on purpose: somebody who knows a username can slow its owner down but cannot lock them out for good.

### When someone loses their authenticator

A member who has lost the device but still has a recovery code signs in with that code.
A member who has lost both needs an administrator to clear the factor: open the member's card, then the moderation menu, then Account, then Clear two-factor.
That calls `DELETE /admin/users/{id}/totp`, which needs the ADMINISTRATOR permission.
It removes the factor and its recovery codes, signs the member out everywhere, and writes a `totp_cleared` row to the moderation audit log naming the administrator.
The member then signs in with their password alone and can enrol again.

An admin-issued password reset code does not clear the factor.
It sets a new password and revokes sessions, and the next sign-in still asks for a code.
So a member who forgot both their password and lost their authenticator needs two admin actions: a reset code and a clear.

### When the only administrator loses both

Read this before you turn the factor on for the account that owns the deployment.
The administrator's clear needs a signed-in session with ADMINISTRATOR, and the sign-in itself asks for a code, so a sole administrator who has lost both the authenticator and the recovery codes cannot use it.
For that case the server binary has a command that works on the database directly:

    slimm-server clear-totp <username>

Run it where the server runs, with the same `SLIMM_DATABASE_PATH` the server uses.
With the compose file that is:

    docker compose exec server /usr/local/bin/slimm-server clear-totp <username>

(`docker compose run --rm server clear-totp <username>` works too, since the image's entrypoint is the binary.)
It removes the factor and its recovery codes, signs the member out everywhere, and writes a `totp_cleared` row to the moderation audit log with no actor, because nobody was signed in.
It prints how many sessions it signed out, and exits non-zero if no account has that name or the account has no factor.
The username is matched without regard to letter case.
It is safe to run beside the server, but a device that is already connected can stay connected until it next reconnects.
The member then signs in with their password alone and can enrol again.

What else is true here:

- If another member holds ADMINISTRATOR, they can clear yours from your card without the command.
- Turning the factor on, and deleting an account, both ask for the account password, so a stolen session token cannot do either (decision 0048).

Keep the recovery codes somewhere other than the phone, and give a second person ADMINISTRATOR before you enrol on the owner account.
[deploy/README.md](../deploy/README.md) covers backups, and a restore from before you enrolled also removes the factor, along with everything else since.

## Usernames

Usernames are unique without regard to letter case, so `Alice` cannot register beside `alice`, and sign-in ignores case.
Migration 0095 added the index.
A deployment that already held a colliding pair kept the name for the account that was active most recently: one with a live session first, then by latest session use, else latest device activity, else latest message, with ties going to the earliest account.
Every other account in the group was renamed to its own name plus `_` and the last eight hex digits of its id.
`username_collision_renames` records the old and new name of each, so you can tell those members what to sign in with.
Display names were not touched.

## Push previews

Whether a notification shows the message text is one choice per account, not per device.
An account that never chose gets `DEFAULT_PUSH_PREVIEW` (`src/notifications.rs`), which is on.
To flip the default for everyone who has not chosen, change that constant and nothing else; the account value is resolved when a push is sealed.
Decision [0054](decisions/0054-push-preview-default-on.md) has the old-client caveat.

## Modules and module sources

Modules are WebAssembly programs the server runs in-process, installed from Modules in Space settings under Addons.
All Dock routes need MANAGE_SERVER.
[modules/building-modules.md](modules/building-modules.md) is the author's guide, and this section is about what you approve.

The official source is the repository in `SLIMM_ADDONS_REPO`.
You can add up to 8 community sources, each a GitHub `owner/repo`, with `POST /space/dock/sources`; list them with `GET /space/dock/sources` and remove one with `DELETE /space/dock/sources/{sourceId}` (decision 0046).
Everything is fetched from `raw.githubusercontent.com`, and only the repository slug is configurable, so a source cannot point at an arbitrary host or at your LAN.

Community sources get the same checks as the official one and no stricter ones: each module's manifest pins its artifact's SHA-256 and the server refuses a mismatch.
Nobody reviews a community module for you, so installing one is trusting its author with whatever you approve for it.
The Dock labels a community module with its `owner/repo`.

- A module id has one owner. The official source always wins, and an id installed from one source cannot be installed from another until it is uninstalled; both refuse with 409.
- Removing a source does not uninstall anything. Modules from it stay installed and enabled but stop receiving updates until the source is added again. The official source cannot be removed.
- Enabling a module is refused with 409 if another enabled module already owns one of its slash keywords.

Approving a module means two separate things.
Its own permissions are granted to roles by you, and nobody holds them implicitly, administrators included.
Its host capabilities are approved per install, in switches that start off.
The Private network switch lets `net.fetch` reach your whole home network, minus this server, its docker host, docker bridge networks and anything in `SLIMM_MODULE_LAN_DENY`.
There are two, `kv.store` (private key-value storage, small and capped) and `message.post` (post as the person who ran the module, in the channel they ran it from).
A new build of a module's wasm loses its `message.post` approval and needs it approved again; `kv.store` carries over.
A module with no approval can compute from its input and nothing else.
Each run is also bounded by memory, wall-clock and fuel limits.
The defaults are 16 MB, 1 second and 50 million fuel, a manifest may raise them, and the host caps them at 256 MB, 10 seconds and 2 billion fuel.

## Webhooks

A webhook lets a tool post into one channel.
Create one in Space settings, under Addons, Webhooks; it needs MANAGE_SERVER.
The URL (`/webhooks/{webhookId}/{token}`) is the credential and is shown once, because the server keeps only a hash of the token.
Rotate replaces the URL and the old one stops working at once; revoke ends the webhook.
Create, rotate and revoke all appear in the moderation audit log.
A webhook can post text and bounded embeds, and cannot read, edit, delete, upload or mention everyone.
[webhooks/pointing-tools-at-slim-m.md](webhooks/pointing-tools-at-slim-m.md) has the payload rules and per-tool notes, and decision 0030 has the model.

## Bots

A bot is an account with a token, made in Space settings under Bots; it needs MANAGE_SERVER.
The token (`slimbot_...`) is shown once.
A new bot holds what `@everyone` holds and nothing more, and you grant the rest through roles like any member, including administrator.
So treat a bot token like an admin password if the bot holds a powerful role.
If one leaks, revoke the bot: its WebSocket closes and its next request returns 401 immediately.
Removing a bot from the Space also revokes its session, and restoring it brings the same token back unless you revoked the token yourself first.
A bot cannot create another bot.
[bots/building-bots.md](bots/building-bots.md) covers what a bot can do, and the choice between webhook, bot and module is decision 0035.

## Backups and restore

Two things need backing up: the SQLite database and the attachment directory.
Litestream, if you enable it, streams only the database.
`scripts/backup.py` takes a consistent snapshot of the database and mirrors the attachment and avatar files it references, with `--keep N` to prune old snapshots.
`scripts/restore-drill.py` restores the newest snapshot to a scratch path, runs `PRAGMA integrity_check`, and checks every referenced file exists with a matching hash.
It exits non-zero on any problem.
Neither script backs up `.env`, which holds your LiveKit and Litestream secrets, or `slimm-data.key`, the key that opens the stored two-factor secrets (see [The data key](#the-data-key)).
The commands, the container invocation and the sensitivity of a snapshot are in [deploy/README.md](../deploy/README.md#backups-optional).
Take a backup immediately before upgrading, because migrations only go forward.

## The web client image

`ghcr.io/slim-m-org/slim-m-web` is nginx plus a release web build, off by default.
Turn it on with `COMPOSE_PROFILES=web` and route `/app` to it from your proxy.
It follows `SLIMM_VERSION` like the server.
If it fails to load channels, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md#the-web-client-says-could-not-load-channels).
[deploy/README.md](../deploy/README.md#web-client-image-slim-m-web) has the Caddy block and the rollback.

## Updating

Set `SLIMM_VERSION` in `.env` to the release you want and run `docker compose up -d`.
Leaving it at `latest` follows whatever `main-builds` last published, which can be an unreleased server build.
Caddy, LiveKit and Litestream are pinned in `docker-compose.yml` and you bump those there.
Rolling the image back is not enough on its own, because migrations are forward-only; you restore a database from before the upgrade and put `SLIMM_VERSION` back to match.
[deploy/README.md](../deploy/README.md#upgrading) has the steps.
If you want to hold clients to a minimum version after an upgrade, set `SLIMM_MIN_CLIENT_VERSION`, and only when an old client genuinely cannot work against the new server.
