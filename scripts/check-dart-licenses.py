#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The Dart half of the dependency-license gate.

cargo-deny covers the Rust tree; pub has no equivalent, so this reads
client/pubspec.lock, finds each hosted package in the pub cache, and
classifies its LICENSE text against the same allowlist cargo-deny uses, the
[licenses] table in deny.toml.

Classification is by license text rather than by a declared field because a
pub package declares no license anywhere in its pubspec; pub.dev derives it
from the LICENSE file too. A package whose text matches nothing known is an
error rather than a pass, since a gate that shrugs at what it cannot read is
not a gate. See docs/ci.md.
"""

import os
import re
from dataclasses import dataclass, field
from typing import NamedTuple
import subprocess
import sys
import tomllib
from pathlib import Path

GNU_FAMILY = [
    ("AGPL", "gnu affero general public license"),
    ("LGPL", "gnu lesser general public license"),
    ("GPL", "gnu general public license"),
]

MARKERS = [
    ("Apache-2.0", ["apache license", "version 2.0"]),
    ("MPL-2.0", ["mozilla public license"]),
    ("CC0-1.0", ["creative commons", "cc0"]),
    ("Unlicense", ["this is free and unencumbered software released into"]),
    ("BSL-1.0", ["boost software license"]),
    ("ISC", ["permission to use, copy, modify, and/or distribute", "above copyright notice"]),
    ("0BSD", ["permission to use, copy, modify, and/or distribute"]),
    ("MIT", ["permission is hereby granted, free of charge", "the software is provided"]),
]

BSD_STEM = "redistribution and use in source and binary forms"

# The one pub host these packages come from, named once.
PUB_HOST = "pub.dev"


def _gnu(head: str) -> str | None:
    """Matched on the title block only: MPL-2.0 names all three in its body."""
    for family, needle in GNU_FAMILY:
        if needle not in head:
            continue
        if "version 3" in head:
            return f"{family}-3.0-only"
        if family == "LGPL":
            return f"{family}-2.1-only"
        return f"{family}-2.0-only"
    return None


def _bsd(flat: str) -> str | None:
    """Which BSD, by the clauses actually present."""
    if BSD_STEM not in flat:
        return None
    if "all advertising materials mentioning features" in flat:
        return "BSD-4-Clause"
    if "endorse or promote" in flat:
        return "BSD-3-Clause"
    if "reproduce the above copyright" in flat:
        return "BSD-2-Clause"
    return "BSD-1-Clause"


def classify(text: str) -> str | None:
    flat = re.sub(r"\s+", " ", text.lower())
    gnu = _gnu(flat[:600])
    if gnu:
        return gnu
    for name, needles in MARKERS:
        if all(n in flat for n in needles):
            return name
    return _bsd(flat)


def _package_lines(text: str) -> list[str]:
    """The indented lines under `packages:`, and nothing else.

    A hand-rolled reader rather than a YAML dependency, because this script
    runs before anything is installed and its whole job is to have no
    dependencies of its own to vouch for.
    """
    lines: list[str] = []
    inside = False
    for raw in text.splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if not raw.startswith(" "):
            inside = raw.startswith("packages:")
            continue
        if inside:
            lines.append(raw)
    return lines


class Locked(NamedTuple):
    name: str
    version: str
    source: str
    checkout: str = ""


def parse_lock(path: Path) -> list[Locked]:
    """Every package in a pubspec.lock."""
    packages: list[Locked] = []
    current: dict[str, str] = {}
    for raw in _package_lines(path.read_text()):
        indent = len(raw) - len(raw.lstrip())
        line = raw.strip()
        if indent == 2 and line.endswith(":"):
            if current:
                packages.append(_finish(current, path))
            current = {"key": line[:-1].strip('"')}
            continue
        if not current:
            continue
        key, _, value = line.partition(":")
        value = value.strip().strip('"')
        if key == "url" and value.endswith(".git"):
            current["repo"] = value.rsplit("/", 1)[-1][: -len(".git")]
        if key == "resolved-ref" and value:
            current["ref"] = value
        if key in ("version", "source", "name") and value:
            current.setdefault(key, value)
    if current:
        packages.append(_finish(current, path))
    return packages


def _finish(entry: dict[str, str], path: Path) -> Locked:
    name = entry.get("name", entry["key"])
    if "version" not in entry or "source" not in entry:
        sys.exit(f"::error file={path}::{name} has no version or source; lock format changed")
    checkout = f"{entry['repo']}-{entry['ref']}" if "repo" in entry and "ref" in entry else ""
    return Locked(name, entry["version"], entry["source"], checkout)


def pub_cache() -> Path:
    """The first candidate root that actually holds unpacked pub.dev packages."""
    candidates = []
    if os.environ.get("PUB_CACHE"):
        candidates.append(Path(os.environ["PUB_CACHE"]))
    candidates.append(Path.home() / ".pub-cache")
    if os.environ.get("XDG_CACHE_HOME"):
        candidates.append(Path(os.environ["XDG_CACHE_HOME"]) / "dart")
    candidates.append(Path.home() / ".cache" / "dart")
    for candidate in candidates:
        if (candidate / "hosted" / PUB_HOST).is_dir():
            return candidate
    sys.exit(
        "::error::no pub cache found in "
        + ", ".join(str(c) for c in candidates)
        + "; run 'flutter pub get' in client/ first"
    )


def license_text(root: Path) -> tuple[Path, str] | None:
    for candidate in ("LICENSE", "LICENSE.md", "LICENSE.txt", "license", "COPYING"):
        path = root / candidate
        if path.is_file():
            return path, path.read_text(errors="replace")
    return None


@dataclass
class Tally:
    """What one pass over the lockfile found."""

    failures: list[str] = field(default_factory=list)
    seen: dict[str, int] = field(default_factory=dict)
    hosted: int = 0
    unpacked: int = 0
    checked: int = 0


def _check_one(
    entry: Locked,
    workspace: set[str],
    cache: Path,
    allowed: set[str],
    exceptions: dict[str, set[str]],
    tally: Tally,
) -> None:
    """Classify one locked package, recording what happened either way."""
    name, version, source, checkout = entry
    if source == "git" and checkout:
        # A git dependency is a pinned checkout, classified from its LICENSE like a hosted one.
        _classify_dir(name, version, cache / "git" / checkout, allowed, exceptions, tally)
        return
    if source != "hosted":
        # A path dependency has no pub licence to read, and the
        # workspace's own packages are covered by this repository's licences.
        if name not in workspace and source != "sdk":
            tally.failures.append(
                f"{name} {version} comes from '{source}', not {PUB_HOST}; classify it by hand")
        return

    tally.hosted += 1
    if not (cache / "hosted" / PUB_HOST / f"{name}-{version}").is_dir():
        return
    tally.unpacked += 1
    _classify_dir(name, version, cache / "hosted" / PUB_HOST / f"{name}-{version}",
                  allowed, exceptions, tally)


def _classify_dir(
    name: str,
    version: str,
    root: Path,
    allowed: set[str],
    exceptions: dict[str, set[str]],
    tally: Tally,
) -> None:
    found = license_text(root)
    if found is None:
        tally.failures.append(f"{name} {version} ships no LICENSE file in the pub cache")
        return
    path, text = found
    spdx = classify(text)
    if spdx is None:
        tally.failures.append(
            f"{name} {version} has a LICENSE this gate cannot identify ({path})")
        return

    tally.checked += 1
    tally.seen[spdx] = tally.seen.get(spdx, 0) + 1
    if spdx not in allowed and spdx not in exceptions.get(name, set()):
        tally.failures.append(f"{name} {version} is {spdx}, which deny.toml does not allow")


def main() -> int:
    root = Path(
        subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    )
    policy = tomllib.loads((root / "deny.toml").read_text())["licenses"]
    allowed = set(policy["allow"])
    exceptions = {e["name"]: set(e["allow"]) for e in policy.get("exceptions", [])}
    cache = pub_cache()

    lock = root / "client" / "pubspec.lock"
    packages = parse_lock(lock)
    if len(packages) < 50:
        print(f"::error file={lock}::only {len(packages)} packages parsed; the gate is not reading the lockfile")
        return 1

    workspace = {p.name for p in (root / "client" / "packages").iterdir() if p.is_dir()}
    tally = Tally()
    for entry in packages:
        _check_one(entry, workspace, cache, allowed, exceptions, tally)

    # A gate that skips what it cannot find would go green on an empty cache.
    if tally.unpacked < tally.hosted:
        tally.failures.insert(
            0,
            f"only {tally.unpacked} of {tally.hosted} locked packages are unpacked "
            f"under {cache}; run 'flutter pub get --enforce-lockfile' in client/ first",
        )

    for line in tally.failures:
        print(f"::error file=client/pubspec.lock::{line}")
    summary = ", ".join(f"{k} {v}" for k, v in sorted(tally.seen.items()))
    print(f"dart licenses: {tally.checked} pub.dev packages checked ({summary})")
    return 1 if tally.failures else 0


if __name__ == "__main__":
    sys.exit(main())
