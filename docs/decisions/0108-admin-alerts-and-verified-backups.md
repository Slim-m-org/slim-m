<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0108 - Verified nightly backups with visible status, and operator alerts

Status: accepted
Date: 2026-11-04
Builds on the manual `scripts/backup.py` and `scripts/restore-drill.py`.

## The ask

Backups were manual and nobody could see whether one had worked.
The owner approved a nightly verified backup that the admin Storage screen reports, and alerts to the people who run the server.

## Backups

- A `backup` compose profile runs `scripts/backup-nightly.py` in a small Python container.
  It runs the backup, then the restore drill, nightly at 03:00 UTC (`SLIMM_BACKUP_HOUR_UTC`), and keeps 14 snapshots (`SLIMM_BACKUP_KEEP`).
- It writes `status.json` (time, size, ok or error, the stage that failed) into a separate volume.
  A failed run keeps the time and size of the last good one, so "last verified" stays true through an outage.
- The server mounts that volume read-only and only reads it.
  The server never runs a backup: a stuck or hostile server cannot rewrite the record, and a slow backup cannot stall the server.
- The data volume is mounted read-only into the container, which reads it as root with one capability (`DAC_READ_SEARCH`).
  Checked against a live WAL database on a read-only mount.
- Storage shows "Never", "Last verified backup: N h ago", or the error, with a warning past 48 hours.
  "Never" is not an alert: a deployment that never turned the profile on has not failed anything.

## Alerts

Six conditions, each one row keyed by kind and subject in `admin_alerts` (migration 0177):

| Kind | Raised when |
| --- | --- |
| `livekit_unreachable` | the reachability probe fails for 2 minutes straight |
| `disk_low` | free space on the data disk is under `SLIMM_ALERT_MIN_DISK_FREE_MB` (default 1024, 0 is off) |
| `sweep_failing` | a recorded sweep has missed 3 scheduled runs, once the process has been up that long |
| `backup` | the newest run failed, the status is unreadable, or the last verified backup is over 48 hours old |
| `module_breaker` | the circuit breaker turns a module off (raised where it trips) |
| `push_relay` | 3 sends in a row never reached the relay |

- A sweep records a run only when it succeeds, so a missed run is a failed pass.
  This needed no change to the sweeps themselves.
- Dedupe: a condition is one row while it lasts.
- Rate limit: one push per kind per 6 hours, however often it flaps.
  The in-app list is not rate limited.
- Recovery: a recovery push goes out only if the opening was pushed.
  The list keeps a recovered alert for 24 hours.
- Audience: accounts holding `MANAGE_SERVER` who have not muted.
  The mute is a column on `users`, set from Storage, and stops the push and the live notice; the list still answers.
- In-app notice: `admin_alerts.changed` carries nothing and is withheld from everyone else, like `reports.changed`; the client refetches `GET /space/alerts`.
- Push rides the relay's existing `security` kind with its own sealed event, so a relay that predates alerts still delivers it.
  The words are the server's own, never member content.

## Not done

- The push relay failing is read from sends, so with no traffic the count holds until the next send gets through.
- Android shows the generic security text for an alert push; the sealed words are read on iOS.
