# 0041 - Per-user installs and signed self-update

Date: 2026-09-28
Status: accepted; the design, the CI signing, the verified download and the Linux, Windows and macOS appliers are built; the macOS one has never run on a real Mac

## Context

The owner, 2026-09-28: "Im not sure how discord does it but they manage to update the app without asking me for dnf permission or anything, I think long term id like to be able to have that sort of seamless updating on all OS's".

Decision 0025 already says the mechanism belongs to the platform, and that self-replacement is reserved for formats the user owns outright, behind a signature check.
Its addendum (PR #1438) makes automatic updates on by default and moves the choice to Settings.
Today that default cannot deliver what the owner describes on the machine he uses: the rpm is a system install, so applying an update means a polkit prompt and `dnf`.
The tarball and AppImage paths in 0020 were gated on client-artifact signing, which does not exist yet.

This record answers the design question and lands the one piece that has no client dependency, the signed manifest.
No self-apply code ships with it.

## How Discord does it

Every Discord desktop install is per-user and lives somewhere the user can already write, so updating needs no elevation.

- Windows: Squirrel.Windows installs under `%LOCALAPPDATA%`, keeps one folder per version (`app-1.0.9xxx`) beside an `Update.exe`, downloads the next version in the background, and on restart the stub launcher runs the newest folder.
- macOS: the app bundle sits in `/Applications` or `~/Applications` and a per-user updater (Squirrel.Mac style) swaps the bundle in place.
- Linux: a tarball unpacked into a user directory, with the updater replacing it and relaunching.

The common shape is a user-writable install, a background download of the whole next version, an atomic switch of which version runs, and a relaunch.
The user never sees a permission prompt because nothing outside their home directory is touched.

## Decision

slim-m adopts that shape on every desktop OS.
Installs are per-user in a user-writable directory, the client downloads a signed manifest and the artifact it names, verifies both, stages the new version beside the running one, switches to it, and relaunches.

### Per OS

Each OS keeps the same five steps: fetch the manifest, verify its signature, download the artifact and check its sha256, stage it beside the current version, switch and relaunch.
What differs is where things live and what the switch is.

| OS | Install location | Update channel | Switch and relaunch |
| --- | --- | --- | --- |
| Windows | `%LOCALAPPDATA%\slim-m\app-<version>\`, with a small stable launcher at `%LOCALAPPDATA%\slim-m\slim-m.exe` | the `windows-x64` zip in the manifest | the launcher reads a `current` pointer file and starts that folder. The updater unzips into a new `app-<version>`, rewrites the pointer atomically, spawns the launcher and exits. A running exe cannot be overwritten on Windows, which is why versions live in separate folders and old ones are pruned on the next start. |
| macOS | `~/Applications/slim-m.app` (a `/Applications` copy is treated as a system install and is not modified unless the user owns it) | the `macos` zip in the manifest | unzip to a sibling `.new` bundle, verify, rename the old bundle to `.old`, rename `.new` into place, open the new bundle and exit. Gatekeeper still applies to a downloaded bundle, so the artifact must be at least ad-hoc signed and stripped of the quarantine attribute by the updater it just verified. Proper Developer ID signing and notarization is a separate owner decision. |
| Linux tarball | `~/.local/share/slim-m/<version>/` with `~/.local/share/slim-m/current` as a symlink and a `~/.local/bin/slim-m` launcher | the `linux-x64` tarball in the manifest | extract into a new version directory, point a temporary symlink at it, `rename(2)` it over `current` (atomic), exec the launcher and exit. The previous directory is kept for rollback. |
| Linux AppImage | wherever the user put it | same tarball channel, or the AppImage's own zsync later | replace the file next to itself and re-exec. Only when the file's directory is writable by the user. |

The desktop shell needs a tiny launcher on Windows and Linux so that "which version runs" is data rather than the path of the running executable.
That launcher is the one piece of new native surface this design adds and it stays deliberately dumb: read the pointer, exec, nothing else.

The launcher can be replaced by an update too, with one exception to "nothing else" on Windows.
On Linux it lives in each version directory and the `~/.local/bin/slim-m` link goes through `current`, so switching versions replaces it.
On Windows the root `slim-m.exe` is running when it matters, so once a version has run cleanly the launcher compares itself with the `slim-m.exe` shipped in that version's folder and swaps itself for it.
It self-tests the copy first, steps the old file aside by rename and renames the copy in, and any failure leaves the old launcher in place.

### Coexisting with the COPR rpm and the flatpak

A system install must never be self-modified.
The client already knows its install format (`currentInstallFormat()`, decision 0020).
The self-apply path is enabled only for formats the updater itself created, meaning the per-user tarball layout above and a user-writable AppImage.

- rpm (COPR `nc1107/slim-m`): keeps updating through `dnf`, and the splash keeps offering the existing install action from 0025.
- flatpak: keeps updating through `flatpak update`.
- deb: same as rpm, through the package manager.

The client never writes into `/usr`, `/opt` or a flatpak's read-only `/app`, and it checks that its own install directory is user-writable before offering to self-apply.
An install that fails that check falls back to the notifier from 0020.
Moving the owner's own machine to the per-user layout is a one-time install, offered rather than forced, and the COPR repo keeps being fed so nobody is stranded.

### The signature scheme

A signed release manifest, not signed individual artifacts, because the manifest is what the client trusts and it is small enough to fetch on every launch.

- Algorithm: ed25519.
  It has small keys and signatures, no parameter choices to get wrong, and a well-supported verifier in Dart (`package:cryptography` or `pinenacl`) so the client needs one pure-Dart dependency and no platform code.
  minisign was considered; it is ed25519 with a comment-and-key-id wrapper, and the wrapper buys nothing for a single-key, single-app scheme, so the raw form is used.
- Manifest: one JSON file with `schema`, `version`, `tag`, and per platform the artifact `url`, `sha256` and `size`.
  It is serialised with sorted keys so the same inputs give the same bytes, and the signature covers those exact bytes.
- Files on the client release: `manifest.json` and `manifest.json.sig` (base64 of the 64-byte signature).
- Public key: 32 raw bytes, base64, compiled into the app.
  The app trusts nothing fetched from GitHub except what verifies against it.
- Order of checks before anything is applied: signature over the manifest bytes, manifest `schema`, `version` strictly newer than the running build (no rollback attack), then sha256 and size of each downloaded artifact.
  Any failure aborts before staging and the current install is untouched.
- Private key: a PKCS8 PEM stored as the `UPDATE_SIGNING_KEY` repository Actions secret.
  It is used only by `update-manifest.yml`, which skips with a warning while the secret is unset.
- Key rotation: the manifest carries no key id today.
  A rotation ships as a client release signed by the old key that embeds both public keys, then the next manifests are signed by the new one.
  The client design must accept a list of keys from the start, even while the list has one entry.

`scripts/update-manifest.py` builds, signs and verifies; `scripts/lib/test_update_manifest.py` covers it against a throwaway key.
The workflow signs with `openssl pkeyutl` because python's standard library has no ed25519, and immediately verifies its own output against the key's public half so a bad secret fails in CI and not on a user's machine.

### Owner's one-time steps

1. Generate the key on a machine you trust: `openssl genpkey -algorithm ed25519 -out update-signing.pem`.
2. Add the file's contents as the repository Actions secret `UPDATE_SIGNING_KEY`, then keep an offline copy (a password manager is enough) and delete the local file.
3. Print the public half with `UPDATE_SIGNING_KEY="$(cat update-signing.pem)" python3 scripts/update-manifest.py pubkey` and hand the base64 string to the client work, which compiles it in.
4. Losing the key means shipping a client release that embeds a new public key, and every install older than that release has to be updated by hand once, so the offline copy matters.

### Rollback and failure modes

- Interrupted download: downloads go to a `.part` file in the staging directory and are resumed or restarted; nothing is staged until the sha256 matches.
  A killed process leaves the old version running and a stale `.part` that the next check deletes.
- Bad signature or hash mismatch: the download is discarded, nothing is staged, and the update is not offered again until a different manifest version appears.
  The failure is shown in the persistent error state, not a SnackBar, and the notifier path from 0020 stays available.
- Disk full: the updater checks free space against the manifest `size` (times two for the unpacked copy) before downloading, and treats a write failure while unpacking the same as a failed download, removing the partial version directory.
- Switch fails or the new version does not start: the previous version directory is kept until the new one has run cleanly for one launch.
  The launcher records a "started" marker; if the new version exits before writing it twice in a row, the launcher moves the pointer back to the previous version and the client reports that the update was rolled back.
- Manifest unreachable, or GitHub rate limits: silent, as in 0025; startup is never delayed past the existing timeout.
- A release with a manifest but a missing platform entry: that platform gets no self-update and falls back to the notifier.

### UX tie-in

- The splash pass from 0025 gains one branch: when the manifest verifies and the install is self-updatable, it downloads and stages during the splash, the status line reads "Installing 0.91.0" with a progress figure, and the app then relaunches into the new version without asking.
  This is the point of the default-on setting in the addendum.
- The title-bar Update item from #1401 stays the manual path.
  With a staged update it reads "Restart to update"; with a known newer version and nothing staged it starts the same download and shows progress in place, and it reuses `relaunch.dart` for the restart.
- A relaunch that lands while the user is in a voice call waits until the call ends, and shows the title-bar item instead of restarting under them.
- Installs that cannot self-update keep exactly today's behaviour, so the copy stays format-specific.

## What is not decided here

- Windows code signing and macOS notarization.
  The manifest signature protects the update channel, not the OS's first-run trust check.
  Both need certificates the owner has not bought.
- Distribution changes such as a Microsoft Store or Mac App Store build.
  Out of scope by the sprint decision; stores update themselves and would sit beside this like the flatpak does.
- Delta updates.
  Whole-version downloads first; the manifest can grow a `delta` field additively later.

## Follow-ups

Backlog cards, one per OS because the swap mechanics differ materially: the Linux per-user tarball updater, the Windows launcher and updater, the macOS bundle swap.
A shared card covers the pure-Dart verify-and-download core they all sit on, and the owner-run key generation is listed above rather than carded.

## Linux applier as built

The version directories sit beside `current` and `previous` symlinks in the layout root, and `install.sh` in the tarball lays that out.
The launcher counts starts in `pending.tries` while a `pending` marker names its own version, and the third start moves `current` back to `previous` and leaves a `rolled-back` marker.
The app clears `pending` and prunes everything but `current` and `previous` after it has stayed up for twenty seconds, and reports a `rolled-back` marker in the persistent error banner.
A tarball that is not in this layout, or whose root is not writable, keeps the notifier behaviour.

## Windows applier as built

The layout root is `%LOCALAPPDATA%\slim-m`, holding `app-<version>` folders, the `slim-m.exe` launcher, and `current` and `previous` as small files that each hold a version number.
The launcher is a Go program in `packaging/windows/launcher`, built with the zip in `desktop-clients.yml`; a symlink is not an option because creating one needs elevation or developer mode.
The updater unzips into an `app-<version>` folder, writes the new pointer through a temp file and a replacing rename, and restarts through the launcher.
The pending-start marker, the third-start rollback, the twenty-second settle and the prune work as on Linux, with the launcher counting starts.
`install.cmd` in the zip and the per-user `slim-m-setup-<version>.exe` (Inno Setup, `packaging/windows/slim-m.iss`) are the first install, and both write this layout.
A bare extracted zip can also move itself into the layout from Settings > About.
Only a layout with the launcher and `current` beside an `app-<version>` folder self-updates: a bare extracted zip, `Program Files` and a packaged MSIX keep the release-page notifier.
The launcher replaces itself once a version has run cleanly, by the self-test and rename swap described above; only a launcher from before that code needs another run of `install.cmd` or the setup.

## macOS applier as built

Any `<name>.app` the user can write is replaceable, found from the running executable: `~/Applications` and a user-owned `/Applications` copy both qualify.
System and library paths, a mounted disk image, a Gatekeeper translocated copy, a sandbox container and an App Store build (it has a `_MASReceipt`) are refused and keep the release-page notifier.
The updater unpacks the `macos` zip with `ditto`, picks out its one `.app`, checks it holds this app's executable and an Info.plist, runs `codesign --verify --deep --strict`, and clears the quarantine attribute.
The swap is two renames in the bundle's own folder: the running bundle to `.<name>.previous`, then the new one in.
There is a window between them with no bundle at the path; a failed second rename undoes the first.
macOS has no launcher, so the app counts its own starts in `pending.tries` under `~/Library/Application Support/slim-m/self-update`, and the third start that still finds `pending` moves the previous bundle back and restarts into it.
That counter only sees starts that reach Dart: a bundle the kernel kills for a bad signature is caught by the verify step before the swap, not by the rollback.
After the app has stayed up for twenty seconds the pending marker and every leftover are cleared, and one previous bundle is kept, as on Linux and Windows, so a subtly broken update can still be reverted by hand; the next update replaces it.
The release zip is ad-hoc signed, not Developer ID signed or notarized.
An ad-hoc bundle that the updater itself downloaded runs because it carries no quarantine flag, but a first install the user downloaded in a browser is still subject to Gatekeeper, and a bundle that loses its signature is refused.
