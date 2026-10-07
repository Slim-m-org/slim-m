# Self-hosting slim-m

A minimal production stack for a friend group.
It wires up the slim-m server, Caddy for automatic TLS, and an optional Litestream sidecar that streams the SQLite database to S3-compatible storage.
Voice and screen share are a second compose file you add when you want them.

Once it is running, [docs/OPERATING.md](../docs/OPERATING.md) lists every setting and covers two-factor, modules, webhooks and bots, and [docs/TROUBLESHOOTING.md](../docs/TROUBLESHOOTING.md) is organised by symptom.

**Text chat on its own is a complete deployment, not a degraded one.**
The server treats a missing SFU as a normal configuration and answers 501 for every voice request, so a group who only want to type need no LiveKit keys and no second DNS record.
Start there; adding voice later is one line in `.env` and does not disturb anything already running.

## Prerequisites

- A host (a VPS, or a box at home with a public IP) with Docker and the Docker Compose plugin installed.
- One DNS record pointed at that host, for the slim-m API domain. Voice needs a second one; see below.
- Ports 80 and 443 (TCP and UDP) reachable from the internet. Voice also needs the UDP media range you choose in `.env`.

### If you are behind CGNAT, or have no public IP

The list above assumes inbound connections reach your host, which is what Caddy needs for a Let's Encrypt certificate and what voice needs for media.
Plenty of residential connections cannot do that: a CGNAT address is shared, so there is no port to forward, and a dynamic address breaks a DNS record every time it changes.
This is not an edge case for the audience this project is for, so it is worth deciding before you start rather than discovering at the first failed call.

Three ways through it, in the order most people should try them:

- **Dynamic DNS**, if you have a real public IP that simply changes. Your router or a client updates the A record; everything else in this document works unchanged.
- **A tunnel** (Cloudflare Tunnel, Tailscale Funnel, or similar), if you have no forwardable port at all. The tunnel terminates TLS and reaches your host outbound, so Caddy's certificate step becomes the tunnel's job rather than yours.
- **LAN only**, deliberately. Everything works between devices on your own network and nothing reaches it from outside, which is a real answer for a household.

**The catch worth knowing before you pick a tunnel.** An HTTP tunnel carries signalling and text, and it does not carry WebRTC media, which is UDP.
So a tunnel can give you a working text deployment and calls that connect and then carry no audio, which looks like a broken app rather than a networking choice.
Voice over a tunnel needs TURN reachable separately (see [Voice and screen share](#voice-and-screen-share) below), or it needs the media ports genuinely forwarded.

The same trap applies to a forwarded deployment that forwards only 80 and 443: signalling works from anywhere, media does not, and calls fail only for people outside your network.
If calls work at home and not away, the media ports are the first thing to check, not the caller's device.

## One-command walkthrough

```bash
git clone https://github.com/Slim-m-org/slim-m.git
cd slim-m
cp deploy/.env.example .env
# edit .env: SLIMM_API_DOMAIN and ACME_EMAIL. That is all that is required.
docker compose up -d
```

## Claim it, before you tell anyone the address

**The first account to register becomes the administrator.**
Do this now, before the domain is in anyone else's hands.

Until somebody registers, the deployment has no roles, no channels and no administrator, so the invite requirement cannot apply - there is nobody to have issued an invite.
Registration is open to whoever reaches it, and by the time `docker compose ps` looks healthy Caddy is already serving the API publicly.
Whoever gets there first is the permanent owner of the space.

That window is usually seconds and usually harmless, and it is how the deployment is meant to be claimed.
It is only dangerous if you stand the stack up, share the address, and register later.
The server says so in its own startup log while it is unclaimed:

```
this deployment has no administrator yet; the first account to register
claims it, so register yours before sharing the address
```

Once you register, that warning stops and joining follows the space's join policy, which defaults to invite-only.

## Getting yourself in

Install a client from [docs/INSTALL.md](../docs/INSTALL.md) - on the same machine the quickest is usually the Linux tarball or, on Fedora, `dnf copr enable nc1107/slim-m && dnf install slim-m-client`.

On first run it asks which space to join. Give it your `SLIMM_API_DOMAIN`, as an https address:

```
https://chat.example.com
```

It will show a **security check** with eight groups of letters and numbers - the server's fingerprint. Compare it against the line your own server logged at startup:

```bash
docker compose logs server | grep "server identity"
```

They should match. This is the one moment where you can confirm it cheaply, and it is the same check you will ask your friends to do.

Then create your account. That first registration claims the deployment and makes you its administrator.

## Letting a friend in

The join policy defaults to invite-only, so your friends need a code rather than just the address.

In the app, go to **Settings → Invites** and create one.
Send them the invite link, which carries both the server address and the code, so they do not have to type either.

They install a client the same way, open the link, and land on the join screen with both fields filled in.
They will see the same fingerprint check you did - tell them what your fingerprint is through some other channel, so the check is worth something.

If you would rather let anyone with the address sign up, there is a **Who can join** pane in settings. Only do that if you are comfortable with strangers registering.

## Adding voice and screen share

Voice lives in `docker-compose.voice.yml`, an overlay rather than a replacement.
Turn it on with one line in `.env`:

```
COMPOSE_FILE=docker-compose.yml:docker-compose.voice.yml
```

Before that line does anything useful you also need to uncomment `LIVEKIT_DOMAIN` in `.env`, point a second A/AAAA record at this host for it, and generate a key pair:

```bash
docker run --rm livekit/livekit-server:v1.10.1 generate-keys
```

Then `docker compose up -d` as usual, and `docker compose ps` shows `livekit` alongside the rest.
You can also pass the files by hand instead of setting `COMPOSE_FILE`:

```bash
docker compose -f docker-compose.yml -f docker-compose.voice.yml up -d
```

Once the overlay is in play the three LiveKit settings are required and Compose refuses to start until they are set, naming the missing one.
That is deliberate: half-configured voice that comes up and then fails at call time is worse than not starting.

The server image tracks the rolling `latest` tag.
Set `SLIMM_VERSION` in `.env` to a published release (see the [releases page](https://github.com/Slim-m-org/slim-m/releases)) to freeze it on a specific version instead.
If you do pin, bump it on every upgrade rather than leaving it: a stale tag is a server that predates every security fix since, and this file itself once shipped pinned to the very first release.
`SLIMM_VERSION` is read from `.env`, so pinning never means editing `docker-compose.yml`.

`LIVEKIT_API_KEY` and `LIVEKIT_API_SECRET` have no defaults, on purpose.
They authorize minting a room token, so a placeholder default would be a publicly known credential on a publicly reachable SFU.

Check it:

```bash
curl https://<SLIMM_API_DOMAIN>/healthz   # -> ok
docker compose ps                         # server and caddy healthy, plus livekit if you enabled voice
```

`curl https://<SLIMM_API_DOMAIN>/version` reports what this deployment can do.
It also carries a `build_id`, the short git SHA the image was built from, which tells two deploys of one version apart.
A build made without one (a local `cargo run`, or `docker build` with no `SLIMM_BUILD_ID` build arg) leaves the field out.
Without the voice overlay it simply has no SFU, which is the expected answer rather than a fault.

## Backups (optional)

Litestream is off by default because it needs a real S3-compatible bucket.
To turn it on: fill in the `LITESTREAM_*` values in `.env`, uncomment `COMPOSE_PROFILES=litestream`, then re-run `docker compose up -d`.

**Litestream replicates only the SQLite database file. Attachment and avatar bytes are not covered.**
They live on disk beside the database, at `SLIMM_ATTACHMENTS_DIR` (default `/data/media` inside the container, so the same `slimm_data` volume as the database), specifically because multi-megabyte blobs in the SQLite file would bloat what Litestream streams for no benefit.
That means restoring from a Litestream replica brings back every message and its attachment references, but not the attachment files themselves; a client would render broken images and failed downloads for anything uploaded since the last time `/data/media` was backed up some other way.

### `scripts/backup.py` and `scripts/restore-drill.py`

These two scripts are the "some other way", and they complement Litestream rather than duplicate it: Litestream is continuous, off-host replication of the database file alone, while these are a periodic snapshot of the database *and* the attachment/avatar bytes together, plus a drill that actually restores and checks one.
Run both if you can; either alone leaves a gap the other closes.

Both are plain-stdlib Python (no pip install), so run them from a throwaway container against the running server's volume - the server image itself is distroless and has no shell or interpreter to exec into:

```bash
docker run --rm \
  -v slimm_data:/data:ro \
  -v "$(pwd)/scripts":/scripts:ro \
  -v /path/on/host/slim-m-backups:/backup \
  python:3-slim \
  python3 /scripts/backup.py --backup-root /backup \
    --database-path /data/slimm.db --media-dir /data/media
```

It takes a `VACUUM INTO` snapshot of the database (a consistent point-in-time copy SQLite produces from inside its own read transaction, safe to take while the server keeps writing through WAL - it does not need the server stopped, and the source volume above is mounted read-only on purpose) and mirrors every attachment and avatar file referenced by that snapshot into `/backup`.
Attachments are content-addressed by their own sha256, so a byte-identical file already mirrored from a previous run is never re-copied; avatars are small, mutable, and few, so they are simply re-copied every run.
Nothing is ever deleted from the mirror by this script, and every copy is an independent one (never a hardlink to the live file) - a backup that could still be corrupted by whatever corrupts the original is not a backup.
Pass `--keep N` to prune older database snapshots (the media mirror itself is never pruned).
Run it on a schedule (cron, systemd timer) the same way you would Litestream.

Then actually restore what you just backed up and check it, rather than trusting that a backup that has never been restored is one:

```bash
docker run --rm \
  -v /path/on/host/slim-m-backups:/backup \
  python:3-slim \
  python3 /scripts/restore-drill.py --backup-root /backup
```

It copies the newest snapshot to a fresh scratch path, runs `PRAGMA integrity_check` on that standalone copy, then checks that every attachment the database references exists in the mirror *and* that the file's real, recomputed sha256 actually matches its name (not merely that a same-named file exists), and the same existence check for every user's avatar.
A snapshot too damaged to query is reported as a failed integrity check rather than a traceback, and the later checks are skipped.
The scratch copy is deleted when the run ends; `--keep-scratch` keeps it, and a directory given with `--scratch-dir` is always yours.
It prints exactly what is missing or corrupt and exits non-zero if anything is, which is the property a restore drill exists for.
Run it after every backup, or at least on a schedule of its own - a backup nobody has restored is a guess.

**The database snapshot is exactly as sensitive as the live database, not merely business data.**
The server's own Ed25519 identity secret (the key a client's trust-on-first-use fingerprint is derived from) lives in that same database as an ordinary row - there is no separate identity file these scripts have to think about excluding, because there is no separate identity file at all.
Treat every snapshot `backup.py` writes with the same care as the running deployment: not a public bucket with no access control, not attached to a bug report.
Neither script touches `deploy/.env` (LiveKit keys, Litestream credentials, ACME email) - those are operator secrets that never reach the database or the media volume, and are yours to back up by whatever means you already use for secrets.

## Browser clients (`SLIMM_CORS_ALLOWED_ORIGINS`)

Empty by default, and that default is the safe one: with nothing set there is no CORS layer at all, and a browser on any other origin is refused.
The desktop and mobile clients send no `Origin` header, so this setting has no effect on them whatsoever.
You only need it if you serve a web build of the client from a different origin than the API.

```
SLIMM_CORS_ALLOWED_ORIGINS=https://app.example.com,http://localhost:8099
```

Deny-by-default matters more here than it looks, and not only for a server on the public internet.
A self-host usually sits on a network your own browser can route to and the rest of the internet cannot.
An open policy would hand every page you happen to visit the ability to drive that deployment from inside the perimeter its network position was protecting it with, using your browser as the way in.
That is why `*` is refused outright rather than accepted as a shortcut, and why the list is exact origins you write down.

Malformed entries stop the server at startup with the offending value named, rather than turning into a `blocked by CORS policy` line in a browser console days later.
An origin is `scheme://host[:port]` and nothing more, so a path, a query, a fragment, or embedded credentials are all rejected.
A default port, an uppercase host, a unicode host, and a bare trailing slash are all normalized to the form a browser actually sends, so those still match.

Credentials are never allowed, whatever you set.
slim-m authenticates with an `Authorization: Bearer` header the client attaches itself; browsers never send that automatically the way they send cookies.
Credentialed mode would therefore buy nothing here while adding the ambient authority that turns one mistaken origin into a full account takeover, so the server does not send `Access-Control-Allow-Credentials` at all.

Only `authorization` and `content-type` are accepted as request headers, and only the methods the API actually serves (`GET`, `POST`, `PUT`, `PATCH`, `DELETE`) are allowed.
Preflights are answered by the server itself and cached for ten minutes.

## Voice and screen share

`SLIMM_LIVEKIT_URL`, `SLIMM_LIVEKIT_API_KEY` and `SLIMM_LIVEKIT_API_SECRET` are what tell the server it has an SFU at all.
Without them the server answers 501 for every voice request, which is a supported way to run text-only but is not what somebody who brought up the `livekit` service is asking for.
The URL must be the one clients reach from outside, not the compose-internal service name, because the server hands it to the client alongside a join token.

LiveKit's signaling channel is fronted by Caddy on the `LIVEKIT_DOMAIN` you set, so no extra port beyond 443 is needed for a client to negotiate a call.
It is plain HTTPS/WSS, so Caddy reverse-proxies it exactly like any other HTTP traffic and passes the `Upgrade: websocket` handshake through with no special configuration.

Carrying the call is separate, and needs four things open at your router or cloud firewall on top of that.
Media never goes through Caddy or port 443 at all: LiveKit's TURN and TURN/TLS listeners bind their own ports directly on the host, and the UDP media range is published straight through to the container.
Caddy is not, and cannot be, in that path.
Docker publishes all four; a firewall in front of Docker does not know that.

| From `.env` | Default | Carries |
| --- | --- | --- |
| `LIVEKIT_UDP_PORT_START`-`LIVEKIT_UDP_PORT_END` | 50000-50100/udp | Call media. The path almost every call actually takes. |
| `LIVEKIT_TURN_RELAY_PORT_START`-`LIVEKIT_TURN_RELAY_PORT_END` | 30000-30100/udp | TURN's relay ports, a separate block from the media range. |
| `LIVEKIT_TURN_UDP_PORT` | 3478/udp | STUN and TURN itself, for clients whose NAT will not do better. |
| `LIVEKIT_TCP_PORT` | 7881/tcp | The fallback for a client that cannot send UDP at all. |

Leaving the TURN relay range closed is worse than having no TURN at all: LiveKit keeps advertising relay candidates and every one of them times out, so calls that would have failed fast instead hang.

The relay range is narrowed from LiveKit's own 30000-40000 default, which nobody publishes ten thousand ports for.
Left at the default the effect is TURN that looks enabled in the config and connects nothing.

Move any of these if something on the host already holds the port.
A UniFi controller publishes 3478 for its own STUN, and a second SFU on the same box already holds 7881.
Both sides of each mapping follow the variable, so changing it in `.env` is enough.

The `livekit` service carries a Docker `HEALTHCHECK` too, same as the server and Caddy: a plain `GET /` against its own signaling port, which LiveKit answers `OK` to with no auth needed.
`docker compose ps` reports its real state, so a LiveKit that starts and then crashloops shows `unhealthy` there rather than looking identical to a working one - see "Monitoring" below for the incident this closes.

### TURN/TLS, and why it is not on 443

TURN/TLS (`turns:`) is off by default, and when you turn it on it does not go on 443.
Caddy already owns 443 for the API and LiveKit signaling domains, and TURN is not an HTTP protocol Caddy can multiplex onto that port alongside them.
LiveKit's TURN/TLS listener gets 5349 instead, the IANA default for `turns:`.

The consequence is worth stating plainly: a client on a network so locked down that only outbound 443 is allowed cannot use TURN/TLS to escape it, because it is not on 443 here.
That is an accepted trade-off for a friend-group deployment, and plain UDP TURN on 3478 already covers ordinary home and NAT networks.

Its listener also needs a certificate of its own.
It cannot borrow Caddy's, because Caddy's ACME storage layout is not a stable path to mount from.

To enable it: point a third DNS name at this host (`turn.example.com`, say), obtain a certificate and key for it by whatever means you like, mount them into the `livekit` container, uncomment the `- "5349:5349"` port line in `docker-compose.voice.yml`, and add these four keys under the existing `turn:` block in `LIVEKIT_CONFIG`:

```yaml
          domain: turn.example.com
          tls_port: 5349
          cert_file: /etc/livekit/turn.crt
          key_file: /etc/livekit/turn.key
```

If LiveKit exits at startup with `could not resolve external IP`, that is your host's DNS, not your firewall.
Ubuntu and Fedora run systemd-resolved, whose `/etc/resolv.conf` names a `127.0.0.53` stub that does not exist inside a container, and LiveKit needs one hostname resolved to discover the address peers must reach it on.
The `dns:` block on the livekit service is there for this; point it at whichever resolvers you prefer.
Nothing else in the container uses them: that one STUN lookup is all they serve, and its target is a public Google host either way.

### Voice events for bots

`docker-compose.voice.yml` points LiveKit's own webhook at `http://server:8080/voice/webhook`, the server's compose-internal address, using the same `LIVEKIT_API_KEY`/`LIVEKIT_API_SECRET` pair voice already needs.
This is what lets a bot see a join, a leave or a screen share the instant it happens instead of polling the roster; see `docs/decisions/0032-voice-participant-webhooks.md`.

Nothing to generate and nothing to open at your firewall: the whole exchange stays on the compose network.
The one thing to know is that LiveKit only reads `LIVEKIT_CONFIG` when its container starts, not on a signal or a hot reload.
Upgrading past the release that added this line needs `docker compose up -d` to actually recreate the `livekit` service, not merely the `server` one - `docker compose up -d` after a `git pull` does this on its own, but a deploy script that only restarts `server` will not pick it up until `livekit` is next recreated some other way.

If you run LiveKit anywhere other than this compose file - a separate host, a different orchestrator - add the block yourself to your own `livekit.yaml`:

```yaml
webhook:
  api_key: your-livekit-api-key
  urls:
    - https://your-server-host/voice/webhook
```

Until this is configured and reachable, nothing breaks. The roster (`GET .../voice/roster`, including its `is_sharing_screen`/`has_video` fields) keeps working exactly as before, `voice.activity` keeps firing, and the three named events (`voice.participant_joined`, `voice.participant_left`, `voice.screen_share_changed`) simply never do.

## Monitoring

`docker compose ps` is the first line of defense: server, Caddy and LiveKit all carry a real `HEALTHCHECK` now, so a crashlooping service shows `unhealthy` there rather than sitting behind a container that merely started.
This closes a real incident: LiveKit crashlooped for half an hour on this project's own deployment while the server's `voice enabled` log line stayed exactly as healthy-looking as ever, because that line is only the server's opinion of its own configuration, never a check that the SFU it names is actually answering.

`GET /metrics` is the deeper answer, for anything that scrapes.
It is gated on an authenticated session holding `MANAGE_SERVER`, the same bit `/space/analytics` already gates on - there is no separate service-account or API-key concept in this server, so point Prometheus (or a plain `curl -H "Authorization: Bearer <token>"`) at it with an admin account's own access token.
It answers Prometheus text exposition format with:

- `slimm_process_resident_memory_bytes` - this process's own resident memory.
- `slimm_requests_total{class="..."}` / `slimm_requests_refused_total{class="..."}` - requests admitted and refused per rate-limit class since the process started (`write`, `read`, `upload`, `canvas`, and so on - see `Class` in `crates/slimm-server/src/ratelimit/class.rs` for the full list and what each covers).
- `slimm_websocket_connections` - currently open WebSocket connections.
- `slimm_livekit_configured` - whether this deployment has an SFU configured at all.
- `slimm_livekit_reachable` - whether the configured SFU answered the server's own last reachability probe. Present only when `slimm_livekit_configured` is `1`; a text-only deployment has nothing to be unreachable, so this line is absent rather than a misleading `0`. This is the same class of gap the `livekit` `HEALTHCHECK` above closes, from the server's point of view rather than Docker's - useful when the server and the SFU are not on the same host, or the SFU is not something this compose file runs at all.

## Your server's identity code, and the question a joiner will ask you

The first time someone connects to an address this app has never seen, the client shows them eight groups of hex and asks them to confirm it with whoever runs the server.
That is you, and the code they are reading is yours.

Your copy is in the server's own log, printed once at every start:

```bash
docker compose logs server | grep "server identity"
```

The line reads `server identity; a joining client shows this code, so confirm it matches fingerprint=dead beef cafe babe feed face 1337 d00d` - the same eight groups in the same order the joiner sees, unquoted.
Grep for `server identity` rather than for `fingerprint`: the field name and its `=` are separated by terminal colour codes, so a grep for `fingerprint=` matches nothing even though the line is right there.
Read it back to them over something neither of you is worried about: in person, or a call you placed.
Not the connection they are asking about, and not a message that arrived through it - an attacker sitting in the middle of that connection can rewrite both halves of the conversation.

It is public information by construction.
Every client that connects is handed the key this is derived from, so there is nothing to protect here: the only thing that matters is that the copy reaching the joiner did not travel through the connection they are checking.

The code is stable for the life of the deployment, and it changes only if the identity row in the database is lost or replaced - restoring an older backup that predates it, say, or starting over with a fresh database on the same address.
When that happens every client that already pinned the old one refuses to continue until a human acknowledges the change, which is the alarm working, not a bug.
Tell your members before you do anything that would cause it.

## Custom emoji, and importing them in bulk

**slim-m ships no emoji of its own.**
There is no bundled set, no default pack, and nothing is fetched from anywhere at startup or on first run.
A deployment has exactly the emoji somebody put into it, which means the images are yours to supply and yours to be sure you have the rights to distribute to everyone on the deployment.
Most emoji packs you can download are somebody's copyrighted artwork under a licence worth reading first.

Anyone with MANAGE_SERVER can upload them one at a time from the client.
For seeding a new deployment, the server binary takes a whole directory at once:

```bash
docker compose run --rm -v /path/to/your/emoji:/emoji:ro server import-emoji /emoji
```

That reuses the `server` service's environment and its `slimm_data` volume, so it writes to the same database and the same media directory the running server reads.
It is safe to run while the server is up.
The container runs as an unprivileged user, so the directory you mount has to be world-readable, and mounting it `:ro` is enough because the import only ever reads from it.
Running the binary directly instead of through compose works the same way: it reads the same `SLIMM_DATABASE_PATH` and `SLIMM_ATTACHMENTS_DIR` the server does, so point those at the deployment and give it a directory.

Each file becomes one emoji named after its filename, minus the extension, lowercased, with spaces and dashes turned into underscores and anything else dropped.
`Big Smile.png` becomes `:big_smile:`, and so does `big-smile.png`.
That is the same normalisation an upload through the client goes through, so a bulk-imported emoji is indistinguishable from an uploaded one afterwards.

What is left has to fit in 32 characters, and that is worth checking a downloaded pack against before you point the import at it, because long descriptive filenames are the norm in one.
A name that does not fit is refused rather than shortened: a truncated name is one that two files can quietly end up sharing, and the report telling you about it is better than an emoji you did not name appearing under a name you did not choose.

You get a line per file and a summary:

```
!!!.png           refused, the filename leaves no usable name (a-z, 0-9 or _)
Big Smile.png     imported as :big_smile:
README.txt        refused, not a supported image, whatever the extension claims
nested            refused, not a regular file, and the import does not recurse
party-parrot.gif  imported as :party_parrot:
2 imported, 0 unchanged, 0 skipped, 3 refused, 0 over the limit
```

Running it again over the same directory reports the two as unchanged and does nothing else:

```
!!!.png           refused, the filename leaves no usable name (a-z, 0-9 or _)
Big Smile.png     unchanged, :big_smile: already has these bytes
README.txt        refused, not a supported image, whatever the extension claims
nested            refused, not a regular file, and the import does not recurse
party-parrot.gif  unchanged, :party_parrot: already has these bytes
0 imported, 2 unchanged, 0 skipped, 3 refused, 0 over the limit
```

What it accepts, and what it will not:

- PNG, JPEG, GIF and WebP, decided by reading the first few bytes of each file rather than by trusting the extension.
  A zip named `.png` is refused, and so is an SVG, which is a script that renders rather than an image.
  A PDF is refused here too, even though the server does accept one as a message attachment: an emoji is drawn inline at the size of a word, and that is a narrower thing than a file somebody downloads.
- One megabyte per file, which is already generous for something drawn at about the size of a line of text.
- Thirty-two characters of name, counted after normalising and without the extension.
  `blobcat_happy_extremely_pleased_indeed.png` is refused with `the name is 38 characters, over the 32 character limit`, which is a different line from the one a filename with no usable characters at all gets, so you are never sent looking for an illegal character that is not there.
- Five hundred emoji per deployment.
  Every client fetches the whole list to render `:shortcode:` at all, so this is a real ceiling and not a soft one.
- The directory you name and no deeper.
  A subdirectory is reported rather than descended into, because a nested pack is how two files quietly end up claiming the same name.

Re-running the same import is safe and is the expected way to add to a pack later.
A file whose emoji already exists with those exact bytes is reported as unchanged and nothing happens.
A file whose name is already taken by a *different* image is skipped, and the image your members already recognise stays exactly as it is.
Changing an emoji's picture is deliberately an explicit act: delete it in the client, then import again.

If the deployment hits the five hundred limit part way through, the emoji imported up to that point stay imported, and every file that did not fit is listed as over the limit.
A file that did not fit leaves nothing behind: both the limit and the name are checked before the image is stored, so a refused file writes no bytes into the media directory and no row into the database, and there is nothing to clean up afterwards.

The command exits non-zero if any file in the directory did not end up as an emoji, so a script notices, and the report above it says which files and why.
A pack folder with a `README` or a `LICENSE` in it will therefore exit non-zero on a run that was otherwise fine, with those files named as the reason.

## Storage, and the ceiling you should set

Attachments and custom emoji are files under the media volume, not rows in the database.
There is no per-account quota and there is no ceiling unless you set one:

```
SLIMM_MAX_TOTAL_ATTACHMENT_BYTES=2147483648
```

That is 2 GiB, which the `.env.example` in this directory ships with.

**A single attachment has its own, separate ceiling.**
The message-attachment allowlist covers images, PDF, mp4 and webm video, mpeg/ogg/wav audio, zip and gzip archives, and plain text (source files, logs, csv, json, yaml, sniffed by content rather than by extension - see `crates/slimm-server/src/media/content_type.rs` for the exact rules).
`SLIMM_ATTACHMENT_MAX_BYTES` bounds any one of those, and it defaults to 1 GiB, which covers most video and long recordings.
Lower it if you want a tighter per-upload cap:

```
SLIMM_ATTACHMENT_MAX_BYTES=104857600
```

That is 100 MiB, an example rather than a recommendation - the same "the right number is your disk, not a guess" reasoning as the total ceiling above applies here too.
The server streams each upload to disk as it arrives rather than buffering it whole, so this ceiling bounds disk use, not the memory one upload costs the process.
Raising it does not raise `SLIMM_MAX_TOTAL_ATTACHMENT_BYTES`; the two are independent, and a single-upload ceiling large enough for video with no deployment-wide ceiling at all is a real, if unusual, choice.
Set it from the volume you actually gave the stack, leaving room for the database to grow.

The default is no ceiling, and that is deliberate rather than an oversight: the right number is the size of your disk, and a guess would either refuse a legitimate upload on a large volume or do nothing on a small one.
Leaving it unset is a supported choice if you would rather watch the volume yourself.

Two things worth knowing about what it does and does not cover.

**It counts attachments and custom emoji, not avatars.**
An avatar is one file per account, overwritten in place, so the total is already bounded by your member count times 2 MiB and no upload can grow it.
They are not rows in the table the ceiling sums, so counting them would need a second mechanism to bound something already bounded.

**Past the ceiling an upload is refused with 507, not 413.**
That distinction exists so a screenshot tells you whose problem it is: a 413 means the sender's file is over the per-upload limit and they should send a smaller one, and a 507 means the volume is full and it is yours.
The refusal happens before any bytes are written, so nothing is left behind to clean up.

An uploaded file that never gets attached to a message is reclaimed by a sweep that runs hourly, two hours after the upload.
A deployment sitting at its ceiling therefore recovers as that sweep works through the backlog, and refuses uploads until it does.

Related, and stated elsewhere in this file but worth repeating here: **Litestream replicates the database only.**
A restore gives you messages and their attachment references, not these bytes. Back the media volume up separately.

## GIF search (optional, off by default)

Unset, a self-host has no GIF search at all: no button anywhere in the client, and the three proxy routes answer 501.
Set both variables to turn it on:

```
SLIMM_GIF_PROVIDER=tenor
SLIMM_GIF_API_KEY=your-key-here
```

`SLIMM_GIF_PROVIDER` is `tenor` or `klipy`, case-insensitively; anything else fails the server at startup, so a typo is caught before anyone notices the button is simply missing.
Tenor's key comes from Google's API console, free; Klipy's from klipy.com.

**Every search, every thumbnail, and the eventual pick all go through this server, never straight from a client to the provider.**
That is the reason this is proxied at all rather than a client-side integration: a client hitting Tenor or Klipy directly would hand it every member's own IP address and everything they typed to find a GIF.
A search result's own token is opaque and expires after a few minutes - never the provider's id or a raw CDN URL - so nothing about displaying results or picking one ever depends on a client learning where the provider actually stores anything.

Picking a result downloads the full image through this server and stores it exactly the way an uploaded attachment is stored: content-addressed, sniffed rather than trusted, checked against both `SLIMM_ATTACHMENT_MAX_BYTES` and `SLIMM_MAX_TOTAL_ATTACHMENT_BYTES` above.
A GIF a member picks is an ordinary attachment from that point on, with no further dependency on the provider or the search that found it.

## Rate limiting, and the one setting you need behind a proxy

The server limits requests per caller with token buckets.
An authenticated caller is keyed by account, so a limit follows them across devices and networks rather than being shed by reconnecting.
Everyone else is keyed by address.

That second half is where a reverse proxy causes a problem, and it is worth understanding before you decide.
The server sees the TCP peer, and behind a proxy the peer is always the proxy, so without any configuration **every unauthenticated caller in the world shares one bucket**.
The password bucket is a burst of five and then one attempt every six seconds, so a single client making one request a second keeps it permanently empty and nobody can sign in.
It also fires by accident when several of you sign in together.

The fix is to tell the server how many proxies you run:

```
SLIMM_TRUST_PROXY_HOPS=1
```

Behind the Caddy in this directory that is `1`.
Add one for each additional proxy in front of it - a CDN in front of Caddy makes it `2`.

**Leave it unset if the server is exposed directly**, and do not guess.
The two ways of getting it wrong are not equally bad.
Too low keys every unauthenticated caller together, which is the problem above: annoying, and self-inflicted only.
Too high reads an address the *client* chose, so any caller can mint themselves an unlimited number of buckets, and the limit stops existing.
That is why the default is zero and why this is not inferred: nothing in a request distinguishes a proxy you run from one you do not.

The header is read from the right, which is what makes a correct setting safe.
A proxy appends the address it saw, so the rightmost entry is the one your own proxy wrote; a caller can prepend as much as they like and never reach it.

Caddy has no built-in per-IP rate limiting, so this cannot be solved in the Caddyfile instead - that needs a third-party module and a custom Caddy build.

## Moderating a member, and what "remove from Space" really is

Two tools sit between deleting a message and deleting an account.

A **timeout** takes away sending, reacting, attaching files, and joining or speaking in voice, for a set time.
It takes away nothing else: the member keeps reading, and keeps seeing every channel they could see before.
It lapses on its own at its deadline, with nothing needing to run on time for that to happen, and a moderator can lift or shorten it early.
Issuing one needs the KICK_MEMBERS permission.

A **removal** ends their access to the deployment.
Every live session is revoked, signing in stops working, invites they had handed out are revoked, and they stop appearing in the member list.
Issuing one needs BAN_MEMBERS, and it is reversible: readmitting them restores the right to sign in, though their devices all sign in again rather than resuming.

Two things about a removal are worth being plain about, because the word undersells one and oversells the other.

**It is a ban in behaviour, not a kick.**
There is no membership row to delete here - one deployment is one community, and holding an account *is* membership - so a removal has to be a standing refusal recorded against the account.
A version that only closed today's sessions would be undone by signing in again.

**It does not stop the same person making a new account** on a Space whose join policy is `open`.
Nothing short of identity verification would, that is well outside what a self-hosted friend group can or should do, and the honest answer is to say so rather than imply a guarantee that is not there.
If that matters to you, set the join policy to `invite`.

Everything a removed member wrote stays exactly where it is, still attributed to them.
Removing somebody is not a reason to rewrite a conversation other people were part of.
Anonymizing their content is what *deleting an account* does, which is a separate and heavier act that the account's own holder chooses.

Neither tool can be used on yourself, nor on a member whose permissions your own do not already include - so holding KICK_MEMBERS is not a way to silence the administrators one at a time.
The last remaining administrator cannot be removed at all.

## Web client image (`slim-m-web`)

CI publishes the browser client as `ghcr.io/slim-m-org/slim-m-web`: nginx plus a release web build, signed with cosign like the server image.
A client merge to `main` moves `latest`, and a server release tags the same version as the server, so `SLIMM_VERSION` pins both.
It runs as a non-root user and listens on port 8080 inside the container, serves the app at `/` and also at `/app/`, and is not started by default.

To run it from this compose file, add `COMPOSE_PROFILES=web` to `.env` and route it from your proxy.
With the bundled Caddy that is one more block in `deploy/Caddyfile`, on the same domain or another one:

```
{$SLIMM_API_DOMAIN} {
	handle /app* {
		reverse_proxy web:8080
	}
	reverse_proxy server:8080
}
```

A web client on the same origin as the API needs no `SLIMM_CORS_ALLOWED_ORIGINS`.
The service carries the `com.centurylinklabs.watchtower.enable` label, so a host running Watchtower with label filtering follows `latest` for the web client the way it does for the server.

An open tab notices a redeploy by itself: the page polls `version.json` every few minutes and when the tab regains focus, and offers a "New version available" pill.
Reloading is always the person's own click, so nothing half-typed is lost.

### Rolling the web client back

The web image has no database, so rolling it back is only a pin.
Set `SLIMM_VERSION` in `.env` to the last good version and run `docker compose up -d`.
Watchtower re-pulls the tag a container already runs and a version tag never moves, so the pin holds until you clear the variable.
That variable also pins the server, so read [If an upgrade goes wrong](#if-an-upgrade-goes-wrong) first: the server half of a rollback has a database in it.
To roll back only the web client, give the `web` service its own pin instead of the shared variable.

### Owner: switching the live host from the hand-copied bundle

This is a one-time change on the host, and CI does not make it.
The host currently unpacks a hand-built tarball into an nginx container through a bind mount.

1. In the host's `docker-compose.override.yml`, replace that nginx service's `image:` with `ghcr.io/slim-m-org/slim-m-web:latest` and delete its bind mount of the unpacked bundle.
2. Add the label `com.centurylinklabs.watchtower.enable: "true"` if the host's Watchtower runs with label filtering.
3. Point the Traefik service at port 8080 instead of 80, since the image runs unprivileged. Keep the router rule as it is. It strips `/app` today and the image answers either way, so nothing about routing changes.
4. `docker compose pull web && docker compose up -d web`, then open the app and check `curl -s https://<host>/app/version.json` names a build id.
5. Delete the old unpacked bundle directory once the new container has served a day.

## Verifying the images

Release images (`slim-m-server` and `slim-m-web`) are signed with cosign in keyless mode, so there is no key to download.
The signature names the GitHub workflow that built the image, and that name includes the repository's owner.
The project moved from `NC1107/slim-m` to `Slim-m-org/slim-m`, so an image signed before the move carries the old owner and one signed after carries the new one.
Accept both:

```
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/(NC1107|Slim-m-org)/slim-m/\.github/workflows/(release|web-image)\.yml@refs/' \
  ghcr.io/slim-m-org/slim-m-server:<version>
```

Swap in `slim-m-web` for the web image, and `ghcr.io/nc1107/...` for an image published before the move.
The continuous `main` and `latest` tags of `slim-m-server` are not signed; only release versions are.

## Files

- `docker-compose.yml` (repository root) - the stack itself.
- `deploy/Caddyfile` - routes the API domain and LiveKit's signaling domain through Caddy, terminating TLS.
- `deploy/.env.example` - every variable the compose file reads, with safe defaults and comments.

## Upgrading

The server image is `${SLIMM_VERSION:-latest}` in `docker-compose.yml`, so upgrading or pinning it is bumping `SLIMM_VERSION` in `.env`, never editing `docker-compose.yml` itself (see the note above).
Caddy, LiveKit, and Litestream are hardcoded tags in `docker-compose.yml`; bump those directly and run `docker compose up -d` again.
Newer patches are at hub.docker.com for Caddy and Litestream and at github.com/livekit/livekit/releases for LiveKit.
The named volumes (`slimm_data`, `caddy_data`, `caddy_config`) are untouched by an image swap.

### If an upgrade goes wrong

**Rolling the image back is not enough on its own.**
Migrations run automatically on every start (`sqlx::migrate!` in `crates/slimm-server/src/db.rs`) and they are forward-only by design, with no down path.
So a newer server has already changed the database by the time you decide you want the older one, and the older one may not recognise what it finds.

Restoring a snapshot is the rollback procedure, not a last resort:

1. `docker compose down` - stop writing before you copy anything.
2. Restore the database from a backup taken *before* the upgrade. See [Backups](#backups-optional); `scripts/backup.py` makes one and `scripts/restore-drill.py` is what proves a backup actually restores.
3. Put `SLIMM_VERSION` back to the version that made that backup.
4. `docker compose up -d`.

Which means the useful moment to take a backup is immediately *before* bumping `SLIMM_VERSION`, not on whatever schedule you otherwise run.
A backup taken after the upgrade restores you to the state you are trying to leave.

Practising this once on a copy, with `scripts/restore-drill.py`, is worth more than reading it: an untested backup is a hope rather than a plan.

Litestream is deliberately held on the 0.3.x line rather than 0.5.x.
0.5 replaced the replica format (WAL segments became LTX), and this example targets the longer-documented, more stable 0.3 config and CLI surface.
Moving to 0.5 is a replica-format migration, not a tag bump.

## Logging (`SLIMM_LOG`)

The server logs at `info` by default; set `SLIMM_LOG=debug` to see per-request spans while chasing a problem.
A debug span is labelled by the matched route template (`/invites/{code}`), never the filled-in path.
So an invite code, a GIF or link-preview proxy token, or a webhook token is not written to the log at any level, and a pasted debug log does not leak a credential.
