# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""perf/baselines/ must not fall far behind the server's own release tags.

perf.yml's baseline job measures each server release and commits its
baseline, so a gap means a run failed or was skipped; see perf/README.md.
A bounded lag, not equality, because the commit lands after the release tag.
GRANDFATHERED_BASELINE keeps the gap from before CI measured reporting as a
skip until the first CI baseline lands, after which the bound applies.
"""

import re
import subprocess
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
BASELINES_DIR = REPO_ROOT / "perf" / "baselines"

# Releases a missing baseline may lag behind before this fails; see the module doc.
MAX_RELEASES_BEHIND = 3

# The newest committed baseline the day this check landed; see the module doc.
GRANDFATHERED_BASELINE = "0.38.0"

VERSION_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")


def _semver_key(version: str) -> tuple[int, int, int]:
    match = VERSION_RE.match(version)
    if not match:
        raise AssertionError(f"{version!r} is not a plain x.y.z version")
    return tuple(int(part) for part in match.groups())


def committed_baseline_versions() -> list[str]:
    """Versions with a committed perf/baselines/<version>.json, oldest first."""
    return sorted((p.stem for p in BASELINES_DIR.glob("*.json")), key=_semver_key)


def published_server_release_versions() -> list[str]:
    """Every `server-vX.Y.Z` tag reachable from this checkout, oldest first."""
    result = subprocess.run(
        ["git", "tag", "-l", "server-v*"],
        cwd=REPO_ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    versions = [
        line.removeprefix("server-v") for line in result.stdout.splitlines() if line.strip()
    ]
    return sorted(versions, key=_semver_key)


class PerfBaselineFreshnessTest(unittest.TestCase):
    def test_newest_baseline_is_not_far_behind_the_newest_release_tag(self):
        releases = published_server_release_versions()
        if not releases:
            self.skipTest("no server-v* tags reachable from this checkout")

        baselines = committed_baseline_versions()
        self.assertTrue(baselines, "perf/baselines/ has no committed baseline at all")

        newest_release = releases[-1]
        newest_baseline = baselines[-1]
        if newest_baseline == newest_release:
            return

        self.assertIn(
            newest_baseline,
            releases,
            f"perf/baselines/{newest_baseline}.json names a version with no "
            f"matching server-v{newest_baseline} release tag",
        )
        behind = len(releases) - 1 - releases.index(newest_baseline)
        recovery = (
            "perf.yml's baseline job commits one per server release; rerun it "
            f"from main for the missing tag: gh workflow run perf.yml -f tag=server-v{newest_release}"
        )
        if newest_baseline == GRANDFATHERED_BASELINE:
            self.skipTest(
                f"perf/baselines/ is {behind} releases behind ({newest_baseline} "
                f"against {newest_release}). This gap predates the check and "
                f"needs a real-hardware measurement, so it reports rather than "
                f"failing; see GRANDFATHERED_BASELINE. {recovery}"
            )
        self.assertLessEqual(
            behind,
            MAX_RELEASES_BEHIND,
            f"perf/baselines/ is {behind} releases behind: the newest "
            f"committed baseline is {newest_baseline}.json but the newest "
            f"published server release is {newest_release}. {recovery}",
        )


if __name__ == "__main__":
    unittest.main()
