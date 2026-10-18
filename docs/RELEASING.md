<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# Releasing

How a slim-m release is cut, what a complete one contains, how to tell when it is not complete, and how to repair it.
[ci.md](ci.md) is the reference for every workflow and explains why each is shaped as it is.
This page is the runbook, and every command in it comes from the workflow files.
All `gh` commands assume `-R Slim-m-org/slim-m`.

## How a release is cut

release-please keeps a standing release PR open for each package: `server`, `client` and `schema`.
Merging a release PR makes the push run of `release.yml` create the tag (`server-v<version>`, `client-v<version>`, `schema-v<version>`) and the GitHub release, and then every publish job for that package runs.
`release.yml` has no tag trigger, because the tag release-please creates with its token would start a second run and publish everything twice.
Server and client version independently.

Three things must be true for this to work:

- `RELEASE_PLEASE_TOKEN` is set and unexpired.
  Without it the release PR is authored by `github-actions`, GitHub holds its runs at `action_required`, and the PR shows only one check.
- The commit's own CI has passed.
  `verify-release-checks.sh` waits up to 180 minutes for the checks named in `required_checks` before any publish job runs.
- The commit is not one that only touched workflows.
  Path-gated client CI never ran there, so a release tagged on it publishes unchecked code.

A release PR whose only content is "Synchronize server versions" has no real changes in it; leave it open.

`release-tag-watchdog` runs hourly.
It reports a manifest version with no matching tag, and re-dispatches `release.yml` on a tag whose verify step timed out, when the checks have since passed and the commit is under 72 hours old.

## What a complete release contains

### Client (`client-v<version>`), 10 assets

Taken from `client-v0.89.0` as it stands now.

| Asset | Made by |
| --- | --- |
| `SHA256SUMS` | `client-checksums.yml`, called by `release.yml` and `desktop-clients.yml`, covers every client download above |
| `SHA256SUMS.android` | `release.yml` |
| `slim-m-client-<version>-1.fc44.x86_64.rpm` | `release.yml` |
| `slim-m-client-<version>-linux-amd64.tar.gz` | `release.yml` |
| `slim-m-client-<version>.flatpak` | `release.yml` |
| `slim-m-client-android.apk` | `release.yml` |
| `slim-m-client-<version>-windows-x64.zip` | `desktop-clients.yml` |
| `slim-m-client-<version>-macos.zip` | `desktop-clients.yml` |
| `manifest.json` | `update-manifest.yml`, called by `release.yml` and `desktop-clients.yml`, the last to attach signs |
| `manifest.json.sig` | `update-manifest.yml` |

A `SHA256SUMS.asc` is added when the GPG secret is set; the workflow skips only that file when it is not.
Alongside the assets, a client release also produces a COPR build and a TestFlight build.
Neither is a release asset.

### Server (`server-v<version>`)

Taken from `server-v0.77.0`: `SHA256SUMS`, `slimm-server-<version>-linux-amd64` and `slimm-server-<version>-linux-arm64`, plus `SHA256SUMS.asc` when the GPG secret is set.
The release also publishes the `ghcr.io/slim-m-org/slim-m-server` image under the version tag and `sha-<commit>`, as a multi-arch manifest signed with cosign.
`latest` moves only when the version is the newest GHCR has seen.
A server release also tags `ghcr.io/slim-m-org/slim-m-web` with the same version.

### Schema (`schema-v<version>`)

No assets.
The tag exists so release-please has an anchor, and `schema-v0.77.0` lists none.

## Verifying a release is complete

Run these after the release PR merges and the run finishes.
A green `release` run is not proof, because a failed need makes a dependent job skip without a word.
That is how `client-v0.89.0` shipped without its Windows zip and without a manifest.

```bash
# the asset list: compare against the tables above
gh release view client-v<version> --json assets --jq '.assets[].name'
gh release view server-v<version> --json assets --jq '.assets[].name'

# the server image: both architectures, and the signature
docker buildx imagetools inspect ghcr.io/slim-m-org/slim-m-server:<version>
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/(NC1107|Slim-m-org)/slim-m/\.github/workflows/(release|web-image)\.yml@refs/' \
  ghcr.io/slim-m-org/slim-m-server:<version>

# COPR: does it hold this version
scripts/copr-behind.sh
```

`scripts/copr-behind.sh` needs `PUBSPEC_VERSION` set to the client version and prints `behind=true` or `behind=false`.
A running server reports its version at `/version`.

## Backfilling a missing asset

### A missing desktop zip

`desktop-clients.yml` runs on a `client-v*` tag push and by hand.
It rebuilds the Windows and macOS zips, attaches them with `--clobber`, and then calls the manifest job, so it also re-signs the manifest.

```bash
gh workflow run desktop-clients.yml --ref main -f tag=client-v<version>
```

The job checks out the tag, but the workflow file that runs is the one on the ref you pass, so `--ref main` builds the tag's contents with main's workflow.

### A missing manifest on its own

`update-manifest.yml` takes `tag` and `require`.
`require` is the comma-separated list of platforms that must already be attached, and defaults to `windows-x64,macos,linux-x64`.
Both `release.yml` and `desktop-clients.yml` call it with `defer: true`, so whichever attaches the last archive signs the manifest, and a backfill should not normally be needed.
A run by hand without `defer` fails when a required archive is missing.

```bash
gh workflow run update-manifest.yml --ref main -f tag=client-v<version> -f require=windows-x64,macos,linux-x64
```

A release known to be short and already superseded is listed in `scripts/release-asset-exempt.txt` so the watchdog stops reporting it ([CHANGING-CI.md](CHANGING-CI.md)).
The release-asset watchdog also reports a release whose `manifest.json` omits a platform whose archive is attached (client 0.88.0 omits `linux-x64`); the same command, from a ref with this change, re-signs it.

It needs the `UPDATE_SIGNING_KEY` secret.
While the secret is unset the job passes with a warning and attaches nothing, so a green run with no `manifest.json` on the release means the secret is missing.

### Anything `release.yml` publishes

Republish by hand on the tag:

```bash
gh workflow run release.yml --ref client-v<version>
```

The run reads the tag as its ref, so the workflow and the checkout are both the tag's own.
A tag cut before `release.yml` had a `workflow_dispatch` trigger has none to run, and the fix is to re-cut the tag on a newer commit.
Re-pushing an old `server-v*` tag republishes that version's own tag and leaves `latest` where it is.

### COPR and the server image

```bash
gh workflow run copr-catch-up.yml --ref main
gh workflow run main-builds.yml --ref main -f server=true -f client=false -f packaging=false
```

`copr-catch-up` submits to COPR only when COPR is behind `client/pubspec.yaml`.
`main-builds` takes three booleans, `server`, `client` and `packaging`; a manual run builds exactly the sides you set.

## What a release without `manifest.json` means

The desktop client reads `manifest.json` and `manifest.json.sig` from the newest non-draft, non-pre-release client release.
If either is missing, that fetch fails and nothing is downloaded, so no per-user install can update to that release.
The clients that update another way are unaffected: the rpm through `dnf`, the flatpak by hand, Android by hand and iOS through TestFlight.
Backfill the manifest as above.

## Rolling back

There is no procedure that removes a release, and none of the workflows unpublishes one.

- Server: set `SLIMM_VERSION` to the last good version and restore a database snapshot taken before the upgrade, because migrations only go forward.
  The steps are in [deploy/README.md](../deploy/README.md#if-an-upgrade-goes-wrong).
  Never edit, rename or delete a migration that has reached `main`.
- Web client: pin `SLIMM_VERSION` on the `web` service, described in the same file.
- Desktop client: self-update never installs a version that is not strictly newer than the running one (decision 0041), so a bad client release is superseded by a newer one and not withdrawn.
  The client skips drafts and pre-releases when it looks for an update, but whether marking a published release as a pre-release is the right way to hide one has not been decided or tried.
- A bad `latest` server image: `main-builds` publishes it from `main`, so reverting the commit on `main` and letting the next run publish is the supported path.

## Worked example: client 0.89.0

The change that wired the Spotify client id into the Windows build moved a step to `shell: bash`.
Git Bash rewrote an environment value that begins with a slash, the Windows compiler was not found, and `desktop-clients` failed on the tag.
The manifest job needs both desktop builds, so it skipped.
The release page looked finished and listed 8 assets.
The workflow was fixed to build under pwsh (#1533) and the release was backfilled, and it now lists all 10 assets.
[CHANGING-CI.md](CHANGING-CI.md) has the rule that came out of it.
