<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# Troubleshooting

For people running a slim-m server.
Each entry is the symptom, the cause, how to check it, and the fix.
Settings are listed in [OPERATING.md](OPERATING.md), and the compose walkthrough is [deploy/README.md](../deploy/README.md).

## Voice joins, then there is no sound or video

Cause: signaling reached the server, but the media path is blocked.
Signaling goes through Caddy on 443, and media does not.
LiveKit's media, TURN and TCP fallback ports are published straight from the host, and a router or cloud firewall in front of Docker does not know that.

Check:

- Forward all four from the internet to the host: `7881/tcp`, `3478/udp`, `30000-30100/udp` (TURN relay) and `50000-50100/udp` (media).
  These are the defaults; `LIVEKIT_TCP_PORT`, `LIVEKIT_TURN_UDP_PORT`, `LIVEKIT_TURN_RELAY_PORT_START`/`_END` and `LIVEKIT_UDP_PORT_START`/`_END` move them.
- TURN over TLS is not configured by default, so a network that allows only outbound 443 cannot reach the server for media.
  [deploy/README.md](../deploy/README.md#turntls-needs-443-and-a-router-that-splits-it-by-name) says how to turn it on; LiveKit only advertises it on 443, whatever `tls_port` says.
- `docker compose ps` should show `livekit` as healthy.

If LiveKit exits at startup with `could not resolve external IP`, that is the host's DNS, not the firewall; see the same section of the deploy guide.

Related symptoms:

- Every voice route answers 501: `SLIMM_LIVEKIT_URL`, `SLIMM_LIVEKIT_API_KEY` and `SLIMM_LIVEKIT_API_SECRET` are not all set, so the server has no SFU.
  Setting them to empty strings is not the same as leaving them out.
  The voice overlay (`COMPOSE_FILE=docker-compose.yml:docker-compose.voice.yml`) sets all three for you.
- Clients try to connect to a name that is not reachable: `SLIMM_LIVEKIT_URL` must be the public `wss://` address clients can reach, not the compose service name.

## The web client says "Could not load channels"

Cause: the browser could not open its local database, so sync never starts and the connection bar reads "Offline, retrying".
Sign-in, the member list and settings still work, because they use plain REST, which is why it looks like a messaging bug.
The database needs `sqlite3.wasm` and `drift_worker.js` served by those exact names from the app's own origin (`client/packages/app/web/README.md`).

Check:

- Open the browser's network tab and look for a 404 on either file.
- Check the version the origin serves: `curl -s https://<host>/app/version.json`.
- If you front the web image with your own proxy, make sure it forwards `.wasm` and `.js` files untouched and does not rewrite them to `index.html`.
- A tab opened before a redeploy can hold a stale service worker; a hard reload (or clearing site data) loads the new bundle.

Fix: use the `slim-m-web` image, which fetches both files at build time and serves them (`docker/web.Dockerfile`).
If you build the web client yourself, run `tool/fetch_web_assets.sh` and remove `build/web` before building, because `flutter build web` does not copy a file that appears in `web/` later.

## Push notifications do not arrive

Cause, most likely: the server has no relay configured.
Push needs `SLIMM_PUSH_RELAY_URL` and `SLIMM_PUSH_RELAY_KEY` together; with neither, the server runs fine and sends no push.

Check:

- The shipped `docker-compose.yml` does not pass either variable to the server container, so on that stack push is off until you add them (for example in a `docker-compose.override.yml`).
- The relay URL must be `https://`.
  A plain `http://` URL is accepted only for a loopback or private address, and any other value stops the server at startup with the variable named.
- The recipient's device must have registered with the server.
  A device that already has the channel open and focused is not pushed to either.
- A member's notification schedule (decision [0033](decisions/0033-notification-schedule.md)), a per-channel setting (decision [0049](decisions/0049-per-channel-notification-behaviour.md)) and a message already read on another device (decision [0034](decisions/0034-read-state-across-devices.md)) all suppress a push on purpose.

## A module will not enable, or does nothing

- Enable answers 409 naming another module: two enabled modules cannot share a slash keyword, so the one that is already enabled keeps it.
  Disable that one, or ask the author of the new one to rename its keyword.
- A manifest with colliding command names, a keyword that cannot be typed, or hidden characters is refused by the server.
- It enables but a capability call fails: `kv.store` and `message.post` work only when an admin approved them for that install.
  A new build of the same module must be approved for `message.post` again.
  See [building-modules.md](modules/building-modules.md#host-capabilities).
- The Dock lists no modules: the official source is a GitHub repository read from `raw.githubusercontent.com` only, so a server with no outbound access to that host sees an empty marketplace.
  `SLIMM_ADDONS_REPO` changes the repository, never the host.

## An update does not install

Start with how the client was installed; [INSTALL.md](INSTALL.md#updates-and-uninstalling) has the table.

- Fedora: `dnf` can answer "Nothing to do" for up to 48 hours after a release because it caches metadata.
  Run `sudo dnf upgrade --refresh slim-m-client`.
  If the COPR itself is behind the release, [ci.md](ci.md) describes `copr-catch-up`.
- Flatpak: there is no remote, so `flatpak update` finds nothing.
  Install the new bundle over the old one.
- A desktop app never updates itself from a release that has no `manifest.json` and `manifest.json.sig`.
  Check: `gh release view client-vX.Y.Z --json assets --jq '.assets[].name'`.
  Fix: [RELEASING.md](RELEASING.md) says how to attach them.
- A Windows or Linux tarball copy that was run from the unzipped folder, a machine-wide copy, the rpm and the flatpak are never replaced by the app.
  Install through `install.cmd` (Windows) or `install.sh` (Linux tarball) to get a self-updating layout.
- Windows shows "Windows protected your PC": the build is unsigned.
  Choose **More info**, then **Run anyway**.
- macOS refuses to open the app: clear the quarantine flag with `xattr -d com.apple.quarantine <path to slim-m.app>`, or right-click and choose Open.
  The self-update on macOS has never run on a real Mac, so treat it as unconfirmed.
- A client reports it is too old: the server has a minimum version set (`SLIMM_MIN_CLIENT_VERSION`).
  Unset it, or have the member update.

## A member is locked out by two-factor

Cause: they turned two-factor on and have neither the authenticator nor a recovery code.
Five wrong codes in a row also lock the factor for 15 minutes, during which even a correct code or a recovery code is refused.
The sign-in screen then says the code is not valid; it does not say the account is locked.

Check: wait 15 minutes and try a code from the authenticator or a recovery code.

Fix:

- An admin opens the member's profile card and chooses **Clear two-factor...** (the `DELETE /admin/users/{id}/totp` route).
  It needs the administrator permission, signs the member out everywhere and writes a `totp_cleared` row to the moderation audit log.
  The member then signs in with the password alone and can turn it on again.
- An admin-issued password reset code does not clear two-factor, so it does not help with this.
- If the locked-out member is the only administrator and has no live session on any device, nothing in the product can clear it.
  See [OPERATING.md](OPERATING.md#two-factor-authentication) for what is and is not possible.
