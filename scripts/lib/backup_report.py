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
    print(f"modules: {len(modules['copied'])}/{modules['total']} data files copied")
    for reason in modules["failed"]:
        print(f"  FAILED  modules/{reason}", file=sys.stderr)
    if removed:
        print(f"pruned {len(removed)} older snapshot(s): {', '.join(removed)}")


def warnings_for(attachments, avatars):
    """Gaps the restore drill judges against the mirror, so they never stop it from running."""
    found = []
    orphaned = len(attachments["missing_source"]) + len(avatars["missing_source"])
    if orphaned:
        found.append(
            f"the live deployment has orphaned database rows with no file behind them ({orphaned})"
        )
    malformed = len(attachments["malformed"]) + len(avatars["malformed"])
    if malformed:
        found.append(
            f"the database holds rows whose id is not a well-formed reference, "
            f"skipped rather than mirrored ({malformed})"
        )
    return found
