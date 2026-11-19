<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# A timed self-hosting walkthrough

A run through everything an operator does, on a clean machine, using only the documents in this repository.
It was done on 2026-11-19 against `main` at `3d09c7654` (server 0.113.0, web client 0.131.0), to find where the documents were wrong before 1.0.
[deploy/README.md](../deploy/README.md) is the guide itself; this page is the record of following it, how long each step took and what broke.
Repeat it before a major release and update the table.

## The machine

- A virtual machine with 4 cores and 6 GB of memory, Ubuntu 24.04, nothing installed but ssh.
- Docker 29.1 and Compose 2.40 from Ubuntu's own packages (`docker.io`, `docker-compose-v2`).
- No public address, so the names were `chat.slimm.internal` and `livekit.slimm.internal` in `/etc/hosts`, and Caddy signed their certificates with its local authority.
- Two headless Chrome browsers in the same machine as the clients, on the web client the deployment serves itself, with Chrome's fake microphone.

## The steps and the clock

| Step | What was run | Time |
| --- | --- | --- |
| Install Docker, Compose and git | `apt-get install docker.io docker-compose-v2 git` | 16 s |
| Get the repository | `git clone` | 3 s |
| Text chat up | `cp deploy/.env.example .env`, two values edited, `docker compose up -d` | 11 s to healthy, images included |
| TLS | nothing; Caddy had a certificate when it reported healthy | 0 s |
| Voice | `generate-keys`, four lines in `.env`, `docker compose up -d` | 7 s, healthy 15 s later |
| Web client | `COMPOSE_PROFILES=web`, the `/app` block in the Caddyfile, `up -d`, `restart caddy` | 4 s |
| Claim the deployment | open `/app/`, Connect to a Space, create the account, confirm it is the administrator | about 1 minute by hand |
| Two setup wizards | four personal steps, six server steps | about 2 minutes, or Skip setup |
| Invite a member | Space menu, Invite a friend; the member opens the link, accepts the terms, creates an account | about 1 minute |
| A call | both click the voice channel | in the call 8 s later, media over UDP |
| The TCP fallback | all UDP to LiveKit dropped with iptables, both rejoin | connected over 7881/tcp within 25 s |
| Backup | `docker compose run --rm --no-deps backup python3 /scripts/backup.py ...` | 0.9 s for a 1.6 MB database and 9 MB of files |
| Restore drill | `... restore-drill.py --backup-root /backup` | 1.4 s |
| Restore into a fresh install | `docker compose down`, a new project, `docker compose run --rm restore`, `up -d` | 36 s to a healthy server with the same five words |
| Upgrade across releases | a 0.30.0 deployment from its own release tag, then `git pull` and `up -d` | 154 migrations on one start, a few seconds |
| Roll an upgrade back | `down`, `run --rm restore --force`, old `SLIMM_VERSION`, `up -d` | 22 s |

From an empty machine to two people talking was eleven minutes, most of it reading.

## What was checked, and against what

- The call was confirmed in LiveKit's own log, not on screen: two participants active, `connectionType: udp`, a selected candidate pair on the media range.
- The fallback was confirmed the same way: with UDP dropped, the selected candidate was `tcp4 host <address>:7881`.
- The restore was confirmed by asking the restored server for a message history, an attachment, an avatar, a profile banner, the space icon and banner, and by comparing its five words.
- The upgrade was confirmed by `PRAGMA integrity_check` and `PRAGMA foreign_key_check` on the migrated database, and by reading back messages, an attachment and an avatar written on 0.30.0 and refreshing a session opened there.

## What broke, and what was done

| Found | Where | Outcome |
| --- | --- | --- |
| A backup that passed its drill restored without the space icon, the space banner or any profile banner, and the server answered 500 for each. Linked-account pictures and kept originals were not backed up either. | `scripts/lib/backup_lib.py` | Fixed: all of them are mirrored and the drill checks them. |
| There was no restore procedure, only "restore the database from a backup". | deploy guide | Fixed: `scripts/restore.py` and the `restore` compose service. |
| The documented backup command named the volume `slimm_data`. Compose calls it `slim-m_slimm_data`, so Docker made an empty volume and the script found no database. | deploy guide | Fixed: the commands go through `docker compose run`. |
| The documented drill command did not mount `scripts/` and could not start. | deploy guide | Fixed the same way. |
| With `SLIMM_BACKUP_DIR` on a host path owned by an ordinary user, the backup service died with a Python traceback. | `backup_lib.py` | It now says the directory must belong to root; documented. |
| "Open in browser" on the invite page, and on the account-link page, led to a 404 from the web client image. | `invite_page.rs`, `link_handoff.rs` | Fixed: both link to the web client's own route. |
| On a LAN-only host LiveKit advertised the public address, so calls between devices on the LAN depend on the router looping traffic back. The guide said to set `SLIMM_LIVEKIT_URL`, which the compose file does not read. | voice overlay | Fixed: `LIVEKIT_USE_EXTERNAL_IP` and `LIVEKIT_NODE_IP`. |
| The guide promised a DNS-01 certificate "see `deploy/Caddyfile`"; the file has none and the pinned Caddy cannot do one. | deploy guide | Corrected, with what Caddy really does for a private name. |
| After editing the Caddyfile for the web client, `docker compose up -d` changed nothing; Caddy needs a restart. | deploy guide | Documented. |
| Taking the pre-upgrade backup with `docker compose run backup` upgraded the server first, because the service depends on it. | deploy guide | The commands use `--no-deps` and say why. |
| An install from before 0.66.0 lost voice on upgrade with only `voice is disabled` in the log. | deploy guide | Documented in Upgrading and in troubleshooting. |
| A pinned image older than the compose file would not start (`SLIMM_PUSH_RELAY_URL is not a valid URL: ""`). | deploy guide | Documented: check out the matching tag. |
| The guide sent people to "Settings, Invites"; the quick route is the Space menu. | deploy guide | Corrected. |
| `SLIMM_DATA_KEY` was listed as not passed by compose; it is. A troubleshooting link pointed at a heading that does not exist. | operating guide | Corrected. |

## Not covered by this run

- A real Let's Encrypt certificate. The machine had no public address, so Caddy's local authority stood in.
- TURN over UDP and TURN/TLS. Both clients were on the server's own network, so neither needed a relay; decision of 2026-11-16 keeps TURN/TLS recommended and off by default, and 7881/tcp as the fallback, which this run did exercise.
- The desktop and phone apps, push notifications, Litestream, the nightly backup schedule and the call-audio listener.
- A deployment with members who have two-factor on, restored without its key.
