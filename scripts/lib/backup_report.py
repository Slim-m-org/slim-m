# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""What backup_lib.py tells the operator about a run, and which of its findings are only warnings."""
import sys


def print_report(dest_db, manifest, removed):
    attachments, avatars, modules = manifest["attachments"], manifest["avatars"], manifest["modules"]
    print(
        f"snapshot: {dest_db} ({manifest['snapshot_bytes']} bytes, "
        f"{manifest['vacuum_seconds']:.3f}s)"
    )
    print(
        f"attachments: {attachments['copied']} copied "
        f"({attachments['repaired']} repaired), "
        f"{attachments['already_present']} already present, "
        f"{len(attachments['missing_source'])} missing on disk"
    )
    for digest in attachments["missing_source"]:
        print(f"  MISSING SOURCE FILE  attachments/{digest}", file=sys.stderr)
    for reason in attachments["malformed"]:
        print(f"  MALFORMED ID  attachments: {reason}", file=sys.stderr)
    print(
        f"avatars: {avatars['copied']} copied, "
        f"{len(avatars['missing_source'])} missing on disk"
    )
    for name in avatars["missing_source"]:
        print(f"  MISSING SOURCE FILE  avatars/{name}", file=sys.stderr)
    for reason in avatars["malformed"]:
        print(f"  MALFORMED ID  avatars: {reason}", file=sys.stderr)
    _print_side_files(manifest["side_files"])
    print(f"modules: {len(modules['copied'])}/{modules['total']} data files copied")
    for reason in modules["failed"]:
        print(f"  FAILED  modules/{reason}", file=sys.stderr)
    if removed:
        print(f"pruned {len(removed)} older snapshot(s): {', '.join(removed)}")


def _print_side_files(side_files):
    print(
        f"banners, icons and originals: {side_files['copied']} copied, "
        f"{side_files['already_present']} already present, "
        f"{len(side_files['missing_source'])} missing on disk"
    )
    for name in side_files["missing_source"]:
        print(f"  MISSING SOURCE FILE  {name}", file=sys.stderr)
    for reason in side_files["malformed"]:
        print(f"  MALFORMED ID  {reason}", file=sys.stderr)


def warnings_for(*mirrors):
    """Gaps the restore drill judges against the mirror, so they never stop it from running."""
    found = []
    orphaned = sum(len(mirror["missing_source"]) for mirror in mirrors)
    if orphaned:
        found.append(
            f"the live deployment has orphaned database rows with no file behind them ({orphaned})"
        )
    malformed = sum(len(mirror["malformed"]) for mirror in mirrors)
    if malformed:
        found.append(
            f"the database holds rows whose id is not a well-formed reference, "
            f"skipped rather than mirrored ({malformed})"
        )
    return found
