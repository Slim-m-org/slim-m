# 0025 - How every surface of slim-m gets its updates

Date: 2026-09-14
Status: accepted; amended 2026-09-14 after the owner chose opt-in updates applied during the splash

## Context

The owner asked for "a proper update strategy" ahead of the beta, after two complaints about the current updater: "I keep getting the pending update screen on launching on Linux even though I'm on latest", and "I don't like how update now just takes me to the release instead of updating my install itself".

Decision 0020 built the first half of this on purpose: a desktop notifier that knows how it was installed and points at the right mechanism, with the apply step gated on signing and repo infrastructure.
Since then two of those gates have opened.
COPR publishes a built and signed rpm repository on every client release (`nc1107/slim-m`, verified on the 0.75.0 run), and the release pipeline is stable enough that every tag now ships Linux, Android and TestFlight builds in one run.
This record is the whole picture: what "update" means on each surface, what the client and server promise each other, and which parts need the owner before they can move.

## What exists today

| Surface | How it ships | How it updates today |
| --- | --- | --- |
| Server | `main-builds` pushes `latest` on every server merge; `release` tags versioned images | Watchtower on the live host polls `latest`; continuous deployment, no pin, rollback by hand |
| Web client | built by hand, tarred, copied to the host, unpacked into an nginx container | manual; Cloudflare edge caches the bundle so a `?v=sN` bust is edited into `index.html` per deploy |
| Linux rpm (the owner) | GitHub release asset, and COPR | splash notifier opens the release page; `dnf` by hand |
| Linux flatpak | GitHub release asset only, no remote | notifier points at `flatpak update`, which has no remote to pull from |
| Linux tarball | GitHub release asset | notifier opens the release page |
| Windows, macOS | unsigned tester archives from `desktop-clients` | nothing; not covered by the notifier |
| Android | signed apk and aab on the GitHub release | nothing automated; Play internal testing is loaded by hand |
| iOS | TestFlight, uploaded by `release` | TestFlight's own update flow |

Two things are missing from every row: the client never learns from the server that it is too old, and the update check blocks startup even when nothing forces it.

## Principles

1. **The mechanism belongs to the platform, not the app.**
   0020's constraint stands: an rpm updates through `dnf`, a flatpak through its remote, a store build through the store, a web page through the browser's cache rules.
   The app's job is to notice, to say so clearly, and to hand off to the right mechanism with as few steps as the platform allows.
   Self-replacement is reserved for the formats the user owns outright (tarball, AppImage), and only behind a signature check.

2. **Compatibility is additive, and the server has one lever.**
   The API only grows (the OpenAPI additive gate already enforces this), so an old client keeps working against a new server.
   The one exception the server may declare is a floor: `min_client_version` in `/version`.
   Below it a client shows a blocking update screen and nothing else; at or above it the client is never interrupted.
   The floor is for retiring a client with a real defect (a data-loss bug, a broken protocol reading), not for nudging.

3. **Updating is opt-in, asked once, and then it just happens.**
   The owner's shape: a new account is asked at signup whether slim-m may keep itself up to date, and an install that already has an account is asked once at the splash.
   With it on, every launch checks during the mini splash and installs what it finds before the app starts, which is the moment an update is least in the way.
   With it off, nothing interrupts startup at all.
   Either answer is an answer, so nothing asks twice; the switch in Settings, under About, is how it changes afterwards.
   A check that fails or times out is silent, and never delays the app by more than its own timeout.

4. **The user always sees both numbers.**
   "You have 0.74.0, 0.75.0 is available" is diagnosable; "Update available" is not.
   The owner's stale-splash report could not be triaged because the prompt showed one number.

5. **One release, every artifact.**
   A `client-v*` tag produces every client artifact in one run, and a server tag produces the server image and the web bundle together.
   A green release with a skipped artifact is a failure (see `docs/OPEN-QUESTIONS.md`, the skipped 0.17.0 iOS build).

## Decision, by surface

### The shared contract

- `/version` carries `min_client_version` (semver string, absent for no floor), set per deployment with `SLIMM_MIN_CLIENT_VERSION`.
  Absent is the default and the ordinary case; a blank value is read as absent, because blank is how a compose file spells "off".
  It is read where it is served rather than carried on `AppState` from `Config`, alone among deployment settings: `AppState` is built literally at 157 sites across the integration tests, and the right value for this one is a property of the build being deployed rather than of the deployment, so it belongs beside the version it qualifies.
- The client compares its own version and, below the floor, replaces the whole app with a "This version can no longer connect" screen carrying the same install action the splash uses - so an rpm user is one polkit prompt from a working client rather than a link to a release page.
- The comparison fails open at every step.
  A pending request, an unreachable server, a version on either side that will not parse, and a server too old to declare a floor all render the app untouched.
  A floor that fails closed is an app nobody can use on a bad network, which is worse than the problem it exists for.
- Re-read on every reconnect, because that is when a server upgrade actually reaches a client that was already running: the container is replaced, every socket drops, and the reconnect is the first moment the new `/version` is visible.
- `/version` already carries `protocol` and `capabilities`; the client keeps reading capabilities per feature (the existing handshake) rather than gating on `protocol` alone.
- A client version is `X.Y.Z`; build metadata after `+` is ignored for comparison, as `parseVersion` already does.

### The splash pass (all desktop formats)

- The preference is three-state on purpose: absent means nobody has been asked, which is what tells "said no" apart from "never asked".
  Absent is what makes the signup screen and the splash each ask once, and neither ask again.
- With it on, the splash checks, and then does whatever this format allows: install it (dnf today), or say a version is there and open the release.
  The status line carries the progress, so "Checking for updates" and "Installing 0.76.0" replace the plain boilerplate while it works.
- Installed is not running: the new files are on disk but the process in memory is the old build, so the splash offers "Restart now" and takes "Later" for an answer.
- A version turned down on the open-the-release path is not offered again until something newer exists, which is the existing dismissal memory.
- The blocking screen exists only for the server floor.

### Fedora rpm (the owner's own install)

- The install runs `pkexec dnf upgrade --refresh -y slim-m-client` (dnf5 on Fedora 41+) and keeps dnf's own last lines for the failure case, so a refused polkit prompt or a broken transaction is diagnosable rather than "update failed".
  The polkit prompt is the system's own consent step; the app never escalates silently.
- Precondition: the COPR repo is enabled.
  The pass reads `dnf repolist --enabled` for `copr:copr.fedorainfracloud.org:nc1107:slim-m`; when missing it runs `dnf copr enable -y nc1107/slim-m` first, behind the same prompt.
- A dnf that fails falls back to the open-the-release path rather than claiming an install that did not happen.
- The rpm spec should carry the COPR `.repo` file so an install from the GitHub asset also lands on the repo (a packaging change, not an app one).

### Flatpak

- Publish a flatpak remote from `release.yml` (`flatpak build-update-repo`, GPG-signed, served from a static host or GitHub Pages) so `flatpak update` has somewhere to pull from.
  Flathub is the long-run answer and a separate process.
- Inside the sandbox the app cannot run `flatpak update`; the action opens the system software centre on the app's page (`appstream://top.npcserver.slimm`) with the instruction as fallback.

### Portable tarball and AppImage

- Self-apply is allowed here and only here: download the asset, verify an ed25519 (minisign) signature against a public key compiled into the app, unpack beside the running install, swap on relaunch.
- The signing key is a CI secret the owner creates; without it this path stays "open release page".
  Cosign keyless is what the server images use, but verifying it inside a Flutter app pulls in far more than a 32-byte key; minisign is the smaller, well-understood tool for this job.

### macOS and Windows

- Adopt the standard updaters, Sparkle and WinSparkle, through the `auto_updater` package, fed by an appcast XML that `release.yml` generates from the GitHub release.
- Both require code signing the owner holds: a Developer ID certificate plus notarization on macOS (the TestFlight setup shows the account exists), and a Windows code-signing certificate or Azure Trusted Signing.
  Until then these stay tester archives and the notifier opens the release page.

### Android

- Automate the Play upload in `release.yml` (internal track) once the owner creates a Play Developer API service account; today the aab is on the GitHub release and Play is loaded by hand.
- In the app, use Play's in-app update API (`in_app_update`) for the flexible flow, so a Play-installed build updates without leaving the app; a sideloaded apk falls back to the notifier opening the release page.
- Amended 2026-11-20: a sideloaded apk now updates itself (#2355): it downloads the verified apk and hands it to the system installer, which needs `REQUEST_INSTALL_PACKAGES`.
  Play restricts that permission and a Play install never needs it, so the appbundle drops it: `android/app/build.gradle.kts` merges `src/play/AndroidManifest.xml` (a `tools:node="remove"`) whenever Gradle builds a bundle task, and the apk keeps it.

### iOS

- TestFlight and later the App Store own the mechanism.
  The app adds nothing but the server-floor screen.

### Web client

- Stop deploying by hand.
  `release` (and `main-builds` for the server's `latest`) builds the web bundle into a `slim-m-web` image (nginx:alpine plus the bundle, `--base-href /app/`), tagged like the server image, with the `?v=<short sha>` cache-bust written into `index.html` and `flutter_bootstrap.js` at build time.
  Watchtower deploys it exactly as it does the server.
- In the page, poll `version.json` every few minutes and on tab focus; when it differs from the running build, show a "New version available, reload" pill.
  The service worker keeps serving the old bundle until a full reload, so the pill is what makes a deploy reach an open tab.
- The Cloudflare browser-cache TTL override remains an owner setting; the build-time bust makes deploys correct regardless.

### Server

- Continuous deployment of `latest` stays (owner's explicit choice, `docs/OPEN-QUESTIONS.md` section 5).
- Rollback is documented as a runbook: set `SLIMM_VERSION` in the host's `.env` to the last good tag and `docker compose up -d`.
  Watchtower only re-pulls the tag a container already runs, and a version tag never moves, so the pin holds until the variable is cleared.
- Every server release also moves the web image, so the two never drift.

## Rollout order

Phase 1, before the beta (client-side, no owner secrets):
the opt-in question at signup and at the splash, the splash install pass with the dnf path for the rpm, and the switch in Settings under About - **done**; and `min_client_version` on the server with the floor screen in the client - **done**; then the web reload pill; the web image built and deployed by CI; the rollback runbook.

Phase 2, owner-gated by certificates:
Sparkle/WinSparkle through `auto_updater` with an appcast; notarized macOS and signed Windows builds.

Phase 3, owner-gated by credentials and hosting:
Play upload automation and in-app updates; the flatpak remote; minisign-signed tarball self-apply.

## What this record does not decide

- A beta or nightly channel.
  Stable `client-v*` only until the owner wants a second channel; the notifier reads one tag prefix.
- Flathub submission.
- Whether the web client should eventually be served by the server binary itself instead of a sidecar image.
  Worth revisiting once the server has a static-file route for another reason.

## Owner items

- Create the Play Developer API service account and add its JSON as a secret.
- Provide the Developer ID certificate and notarization credentials, and a Windows signing certificate.
- Create a minisign key pair and add the private key as a secret; the public key goes in the app.
- Set Cloudflare's browser cache TTL to respect origin headers, or add a cache rule for `/app/*.js`.

## Addendum 2026-09-29 - the choice moves to Settings, on by default

The owner reviewed the signup flow for people joining the official server and decided the desktop "keep slim-m up to date?" screen does not belong in it.
The terms checkbox stays; the update question goes.

- Nothing asks about updates during signup, and the splash no longer asks an install that already has an account.
  The screen between sign-up and the first channel is removed for every entry path.
- The preference defaults to on.
  An absent key now reads as on rather than as "never asked", so the three-state reading in principle 3 and in the splash section no longer applies.
- A saved answer of either kind is kept, so an install that already chose off stays off.
- The switch in Settings, under About, is the one place the choice is made or changed.
- A signed-out desktop install now also checks on launch, because the default no longer waits for an account.
