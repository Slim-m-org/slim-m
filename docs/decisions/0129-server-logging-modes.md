<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0129 - One server logging component, three modes an admin switches live, and log files that survive a redeploy

Status: accepted, 2026-11-19.

## The ask

The owner, 2026-11-19: "lets do a logging overhaul if needed as I want to have a debug log mode on spaces we can enable to get way better logging for bug fixing and error finding later on, id like a centralized component with toggleable debug modes, where its either verbose, compact debug, or off no non critical logs shown and i also dont want to lose logs on reboots".

The same day a 16-hour call kept dropping, and the server's side of it was gone: every redeploy (Watchtower recreating the container) and every host reboot wipes `docker logs`.
Only LiveKit's container still had its lines.

## What there was

- `lib.rs` installed `tracing_subscriber::fmt()` once at startup with `SLIMM_LOG` as an `EnvFilter` (default `info`), writing to stdout only.
  Changing it meant editing the environment and restarting the server, which is the moment the evidence is lost.
- About 50 `info!`, 190 `warn!` and 10 `debug!` lines across the server, and a `TraceLayer` that already labels its span by route template so a credential in a path never reaches a log line.
- On the client, `AppLog` feeds a 200-entry ring (`DebugLog`) that members can send to the admins (`/debug-logs`); it already survives an app restart.

## Decision

### One component: `crates/slimm-server/src/logging.rs`

Every server log line goes through one stack, installed once by `run`:
the `EnvFilter` behind a `reload` handle, a per-call-site throttle, and two `fmt` layers that share one mode-aware formatter - stdout (as before, for `docker logs`) and the log files.
The serve path no longer calls `tracing_subscriber::fmt()` itself; the two operator subcommands (`import-emoji`, `clear-totp`) keep their stderr-only setup because their stdout is a report.

### Three modes, switched at runtime by a space admin

`space_settings.log_mode` (migration 0202) holds `off`, `compact` or `verbose`; `PATCH /space/settings` takes `debug_logging`, gated on Manage server and audited like every other settings change.
The handler writes the row and swaps the filter and the line layout in place; the next event already follows it, with no restart.
The server reads the row at startup, so a mode survives a restart too.

| Mode | What it logs | Line layout |
| --- | --- | --- |
| Off | `SLIMM_LOG` exactly as today, `info` when unset | today's layout |
| Compact | Off, plus `debug` from calls and voice, sync and the socket, presence, sign-in, push and media, plus one line per HTTP request (route template, status, latency) | one short line, span fields flattened |
| Verbose | Off, plus every `debug` and `trace` line slim-m writes, and request start lines | adds source file, line and thread |

Off is today's `info`, not something quieter.
On the live deployment `info` is already only lifecycle and notable events (13 lines in a day; the request spans are `debug`), so it is the "critical events only" the owner asked for, and making production quieter than today would only lose the startup and sweep lines an operator reads first.
`SLIMM_LOG` stays the floor every mode adds to, so an operator who set `SLIMM_LOG=debug` keeps it in Off.
Dependencies (sqlx, hyper, the LiveKit client) stay at the floor in every mode: their debug output is volume, not evidence.

So that the modes have something to show, the subsystems the owner hunts bugs in gained a few one-line debug events with key fields: a socket opening and closing (with why, and how long it lived), sign-in and refresh outcomes, a voice join token being issued, and every LiveKit webhook (event, room, participant, and LiveKit's disconnect reason, now parsed).

Verbose is rate-limited: a call site may write at most 50 debug or trace lines a second, and the rest are counted and reported once a minute at `info`.
`info`, `warn` and `error` are never throttled.

### Persistence: rotating files on the data volume

The same lines go, without colour codes, to `slimm-server.YYYY-MM-DD.NNN.log` in a `logs` directory beside the database, which is `/data/logs` in the image: the volume that already outlives a container being recreated, a redeploy and a host reboot.
Nothing in compose changes for that, and the backup container copies the database, media and modules by name, so logs never bloat a backup.

- A new file starts each UTC day and whenever one reaches an eighth of the total budget (at most 32 MiB).
- A restart appends to today's newest file, so the lines just before a crash or redeploy sit next to the ones after it.
- Kept for `SLIMM_LOG_KEEP_DAYS` days (14) and at most `SLIMM_LOG_MAX_BYTES` in total (256 MiB); the oldest file goes first. `SLIMM_LOG_MAX_BYTES=0` writes no files. `SLIMM_LOG_DIR` moves them.
- The directory is 0700 and each file 0600, like the data key.
- A writer thread owns the files, so a slow disk never stalls a request; it flushes whenever its queue runs dry, and a full queue drops the line and counts it rather than blocking.
- If the directory cannot be opened the server says so once and logs to stdout only, rather than refusing to start.

Verbose fills the budget fastest, so on a busy space it shortens how far back the files reach; the size bound is what keeps it safe to leave on.

### Reading them

- An admin downloads the newest 16 MiB from Space settings, Debug logs, through `GET /space/server-logs` (Manage server).
- An operator reads `/data/logs` directly, for example `docker compose exec server ls /data/logs` or the volume path on the host.

### What never reaches a log, in any mode

Passwords, access and refresh tokens, ws tickets, invite codes, webhook tokens and message content.
The request span is labelled by route template (unchanged), the new debug events carry only ids, counts and reasons, and `tests/it_infra/space_logging.rs` signs up, signs in, refreshes and posts a message under Verbose and fails if the password, any token or the message text appears in the files.

### Clients follow the mode, a little

`/version` carries `debug_logging`, and `SpaceSettingsChanged` makes every client re-read it.
While a signed-in space is not Off, the app's own debug log keeps 2000 entries instead of 200, so a log a member sends after a long call still reaches back to its start, and the log a member sends says which mode the space was in.
Nothing else in the client changes: it already records every level, keeps its log across a restart and scrubs it before sending.

## Not done

- No log shipping to an external service; a home server's operator reads files.
- No per-user or per-channel filtering; the mode is the whole space's.
- No automatic switch back to Off; the size bound makes leaving Verbose on harmless, only shorter-reaching.
- The listener, relay and LiveKit keep their own logging.
