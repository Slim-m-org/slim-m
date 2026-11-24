<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0135 - The Fedora COPR channel follows main, and only main publishes

Status: accepted (owner, 2026-11-24)
Date: 2026-11-24
Extends: 0025 (distribution channels)

## The question

`nc1107/slim-m` is the one COPR project.
`main-builds` submits a snapshot of every client or packaging push to `main` into it, and `release` submits the tagged build.
A snapshot's Release sorts above the tagged release of the same version, so a Fedora user who enables the project follows `main`, not releases.
An audit asked whether snapshots belong in a separate nightly project.

## Decision

The owner chose to keep one channel.
The COPR project follows `main` on purpose, and the install docs say so plainly.
No nightly project is created.

Two rules keep that channel safe:

- Only a run on `refs/heads/main` may publish.
  Every job in `main-builds` and `copr-catch-up` that pushes outside GitHub artifacts (the web, server and listener images, COPR and TestFlight) refuses any other ref.
  A branch dispatch still builds the Linux tarball, rpm and Android bundle as run artifacts.
- A re-run of an older `main-builds` run pushes only its `sha-<commit>` tag, and never moves `latest` backwards.

## Consequences

- Fedora users get unreleased builds through `dnf upgrade`, as they do today.
- `docs/INSTALL.md` and `docs/ci.md` describe the COPR channel as tracking main.
- `scripts/lib/test_publishing_jobs_refuse_non_main.py` fails when a publishing job loses its main-only guard.
