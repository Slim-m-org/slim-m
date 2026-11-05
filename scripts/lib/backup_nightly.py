# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Runs backup.py's logic and then restore-drill.py's, and writes the outcome to a status file.

This is the body of the `backup` compose profile (deploy/README.md, "Nightly verified
backups"). The server reads `status.json` from a read-only mount and shows it in Storage; it
never starts a backup itself. The file is replaced atomically, and a failed run keeps the
time of the last good one so "last verified" stays truthful through an outage.
"""
import argparse
import contextlib
import io
import json
import os
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import backup_lib
import restore_drill_lib

STATUS_FILE = "status.json"
MAX_ERROR_CHARS = 300


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--database-path", default=os.environ.get("SLIMM_DATABASE_PATH", "/data/slimm.db"))
    parser.add_argument("--media-dir", default=os.environ.get("SLIMM_ATTACHMENTS_DIR", "/data/media"))
    parser.add_argument("--modules-dir", default=os.environ.get("SLIMM_MODULES_DIR"))
    parser.add_argument("--backup-root", required=True)
    parser.add_argument("--status-dir", required=True, help="where status.json is written")
    parser.add_argument("--keep", type=int, default=14, help="database snapshots to keep")
    parser.add_argument("--at-hour", type=int, default=3, help="UTC hour of the nightly run")
    parser.add_argument("--once", action="store_true", help="run one backup and exit")
    return parser.parse_args(argv)


def _last_line(text):
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    return lines[-1] if lines else ""


def _captured(fn, argv):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            code = fn(argv)
        except Exception as exc:  # noqa: BLE001 - any failure is a failed backup, not a crash
            err.write(f"{type(exc).__name__}: {exc}\n")
            code = 1
    return code, out.getvalue(), err.getvalue()


def _backup_argv(args):
    argv = ["--database-path", args.database_path, "--media-dir", args.media_dir,
            "--backup-root", args.backup_root, "--keep", str(args.keep)]
    if args.modules_dir:
        argv += ["--modules-dir", args.modules_dir]
    return argv


def _backup(args):
    code, out, err = _captured(lambda argv: backup_lib.run(backup_lib.parse_args(argv)),
                               _backup_argv(args))
    return code == 0, _last_line(err) or _last_line(out)


def _drill(args):
    code, out, err = _captured(lambda argv: restore_drill_lib.run(restore_drill_lib.parse_args(argv)),
                               ["--backup-root", args.backup_root])
    if code == 0:
        return True, ""
    problems = [line.strip() for line in (out + err).splitlines()
                if line.strip() and line.strip() != "FAIL"]
    return False, problems[-1] if problems else "the restore drill failed"


def _newest_snapshot_bytes(backup_root):
    snapshots = sorted(Path(backup_root, "db").glob("slimm-*.db"))
    return snapshots[-1].stat().st_size if snapshots else None


def _previous(status_dir):
    try:
        return json.loads(Path(status_dir, STATUS_FILE).read_text())
    except (OSError, ValueError):
        return {}


def write_status(status_dir, status):
    directory = Path(status_dir)
    directory.mkdir(parents=True, exist_ok=True)
    partial = directory / f".{STATUS_FILE}.partial"
    partial.write_text(json.dumps(status, indent=2))
    os.replace(partial, directory / STATUS_FILE)


def run_once(args, now_ms=None):
    """One backup then one drill; returns the status that was written."""
    started = time.time()
    previous = _previous(args.status_dir)
    ok, error = _backup(args)
    stage = "backup"
    if ok:
        stage = "drill"
        ok, error = _drill(args)
    finished_ms = now_ms if now_ms is not None else int(time.time() * 1000)
    size = _newest_snapshot_bytes(args.backup_root)
    status = {
        "version": 1,
        "ok": ok,
        "stage": stage,
        "error": None if ok else f"{stage}: {error}"[:MAX_ERROR_CHARS],
        "finished_at_ms": finished_ms,
        "duration_s": round(time.time() - started, 1),
        "snapshot_bytes": size,
        "last_verified_at_ms": finished_ms if ok else previous.get("last_verified_at_ms"),
        "last_verified_bytes": size if ok else previous.get("last_verified_bytes"),
    }
    write_status(args.status_dir, status)
    return status


def seconds_until(now, hour):
    """Seconds from `now` (aware, UTC) to the next `hour`:00."""
    target = now.replace(hour=hour, minute=0, second=0, microsecond=0)
    if target <= now:
        target += timedelta(days=1)
    return (target - now).total_seconds()


def main(argv):
    args = parse_args(argv)
    if args.once:
        return 0 if run_once(args)["ok"] else 1
    if not Path(args.status_dir, STATUS_FILE).exists():
        run_once(args)
    while True:
        time.sleep(seconds_until(datetime.now(timezone.utc), args.at_hour))
        status = run_once(args)
        print(f"backup {'verified' if status['ok'] else 'FAILED: ' + status['error']}", flush=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
