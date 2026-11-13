#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Fail when a published release is missing assets its kind always carries.

release-please publishes the GitHub Release before any asset job runs, so a
release is public while its builds can still fail; client 0.89.0 shipped
without its Windows zip and update manifest and nothing said so. See
docs/ci.md, "release-asset-watchdog".

`judge` is pure so scripts/lib/test_check_release_assets.py can drive it.
Exit 0 when every judged release is complete or still pending, 1 when one
is missing assets.
"""

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone

DEFAULT_REPO = "Slim-m-org/slim-m"

# One regex per required asset; {v} is the tag's version (docs/ci.md, release-asset-watchdog).
REQUIRED = {
    "client-v": [
        r"manifest\.json",
        r"manifest\.json\.sig",
        r"SHA256SUMS",
        r"SHA256SUMS\.android",
        r"slim-m-client-{v}-\d+\.fc\d+\.x86_64\.rpm",
        r"slim-m-client-{v}-linux-amd64\.tar\.gz",
        r"slim-m-client-{v}-macos\.zip",
        r"slim-m-client-{v}-windows-x64\.zip",
        r"slim-m-client-{v}\.flatpak",
        # The arm64-v8a apk is the one phones take; releases before the per-ABI split carry the one fat apk under the bare name.
        r"slim-m-client-android(-arm64-v8a)?\.apk",
    ],
    "server-v": [
        r"SHA256SUMS",
        r"slimm-server-{v}-linux-amd64",
        r"slimm-server-{v}-linux-arm64",
    ],
}


# Manifest platform -> the asset it must describe when that asset is attached (scripts/update-manifest.py PLATFORMS).
MANIFEST_PLATFORMS = {
    "linux-x64": r"slim-m-client-{v}-linux-amd64\.tar\.gz",
    "windows-x64": r"slim-m-client-{v}-windows-x64\.zip",
    "macos": r"slim-m-client-{v}-macos\.zip",
}


def describe(pattern, version):
    """A pattern as a readable file name, e.g. slim-m-client-0.89.0-windows-x64.zip."""
    name = pattern.format(v=version)
    name = name.replace(r"\d+\.fc\d+", "<n>.fc<nn>").replace("(-arm64-v8a)?", "-arm64-v8a")
    return name.replace("\\", "")


def unlisted_platforms(version, names, manifest_platforms):
    """Platforms whose asset is attached but absent from the signed manifest."""
    if manifest_platforms is None:
        return []
    return [
        f"manifest.json listing {platform}"
        for platform, pattern in MANIFEST_PLATFORMS.items()
        if platform not in manifest_platforms
        and any(re.fullmatch(pattern.format(v=version), n) for n in names)
    ]


EXEMPT_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "release-asset-exempt.txt")


def exempt_tags(path=EXEMPT_FILE):
    """Tags this check skips: one per line, the reason after the tag, # for notes."""
    try:
        lines = open(path, encoding="utf-8").read().splitlines()
    except FileNotFoundError:
        return set()
    return {ln.split()[0] for ln in lines if ln.strip() and not ln.lstrip().startswith("#")}


def judge(tag, names, published_at, now, grace, manifest_platforms=None, exempt=None):
    """Returns (status, missing): status is ok, pending, incomplete or ignored.

    manifest_platforms is the platform set the release's manifest.json lists,
    or None when it was not read; a client release is incomplete while the
    manifest omits a platform whose asset is attached.
    """
    prefix = next((p for p in REQUIRED if tag.startswith(p)), None)
    if prefix is None or tag in (exempt_tags() if exempt is None else exempt):
        return "ignored", []
    version = re.escape(tag[len(prefix):])
    missing = [
        describe(pattern, tag[len(prefix):])
        for pattern in REQUIRED[prefix]
        if not any(re.fullmatch(pattern.format(v=version), n) for n in names)
    ]
    if prefix == "client-v":
        missing += unlisted_platforms(version, names, manifest_platforms)
    if not missing:
        return "ok", []
    if now - published_at < grace:
        return "pending", missing
    return "incomplete", missing


def gh_get(path):
    done = subprocess.run(
        ["gh", "api", path], capture_output=True, text=True, check=True
    )
    return json.loads(done.stdout)


def usable_names(release):
    """Asset names, leaving out an empty upload, which is as good as absent."""
    return [a["name"] for a in release.get("assets", []) if a.get("size", 1) > 0]


def manifest_platforms(repo, tag, names):
    """Platforms the release's manifest.json lists, or None when there is none to read."""
    if "manifest.json" not in names:
        return None
    done = subprocess.run(
        ["gh", "release", "download", tag, "--repo", repo, "--pattern", "manifest.json", "--output", "-"],
        capture_output=True, text=True, check=True,
    )
    return set(json.loads(done.stdout).get("artifacts", {}))


def parse_time(stamp):
    return datetime.fromisoformat(stamp.replace("Z", "+00:00"))


def releases_to_check(repo, tag, recent_days, now):
    if tag:
        return [gh_get(f"repos/{repo}/releases/tags/{tag}")]
    cutoff = now - timedelta(days=recent_days)
    listing = gh_get(f"repos/{repo}/releases?per_page=100")
    return [
        r for r in listing
        if not r.get("draft") and parse_time(r["published_at"]) >= cutoff
    ]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("tag", nargs="?", help="one release tag, e.g. client-v0.89.0")
    ap.add_argument("--recent", type=float, metavar="DAYS",
                    help="every client-v* and server-v* release published in this window")
    ap.add_argument("--grace-minutes", type=float, default=90,
                    help="a release younger than this is pending, not failing")
    ap.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", DEFAULT_REPO))
    args = ap.parse_args(argv)
    if bool(args.tag) == (args.recent is not None):
        ap.error("give a tag or --recent DAYS, not both and not neither")

    now = datetime.now(timezone.utc)
    grace = timedelta(minutes=args.grace_minutes)
    failed = False
    for release in releases_to_check(args.repo, args.tag, args.recent, now):
        tag = release["tag_name"]
        names = usable_names(release)
        listed = manifest_platforms(args.repo, tag, names) if tag.startswith("client-v") else None
        status, missing = judge(
            tag, names, parse_time(release["published_at"]), now, grace, listed
        )
        if status == "ignored":
            continue
        detail = f": missing {', '.join(missing)}" if missing else ""
        print(f"{status.upper():10} {tag}{detail}")
        failed = failed or status == "incomplete"
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
