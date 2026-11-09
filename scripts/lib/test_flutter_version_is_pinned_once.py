# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Every workflow, action and Dockerfile pins the same Flutter version.

The pin is spelled in many places and nothing else connects them, so missing
one leaves a job on a different Flutter than the rest and nothing fails.
`docker/web.Dockerfile` cannot read a composite action, which is why this is a
test rather than a shared action.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PIN = re.compile(r"flutter-version:\s*['\"]?([\w.+-]+)['\"]?\s*$", re.M)
ARG = re.compile(r"^ARG FLUTTER_VERSION=(\S+)\s*$", re.M)
COMMIT = re.compile(r"^ARG FLUTTER_COMMIT=([0-9a-f]{40})\s*$", re.M)
CHECK = 'test "$(git -C /opt/flutter rev-parse HEAD)" = "${FLUTTER_COMMIT}"'


def pins() -> dict[str, list[str]]:
    found = {}
    sources = [*sorted((ROOT / ".github").rglob("*.yml"))]
    for path in sources:
        versions = PIN.findall(path.read_text())
        if versions:
            found[str(path.relative_to(ROOT))] = versions
    for path in sorted((ROOT / "docker").glob("*.Dockerfile")):
        versions = ARG.findall(path.read_text())
        if versions:
            found[str(path.relative_to(ROOT))] = versions
    return found


class FlutterVersionIsPinnedOnceTest(unittest.TestCase):
    def test_the_pins_are_found(self):
        found = pins()
        self.assertIn("docker/web.Dockerfile", found)
        self.assertGreater(sum(len(v) for v in found.values()), 15)

    def test_every_pin_is_the_same_version(self):
        versions = {v for vs in pins().values() for v in vs}
        self.assertEqual(len(versions), 1, f"Flutter is pinned to more than one version: {pins()}")

    def test_the_web_image_checks_the_flutter_tag_against_a_full_commit(self):
        text = (ROOT / "docker" / "web.Dockerfile").read_text()
        self.assertEqual(len(COMMIT.findall(text)), 1, "FLUTTER_COMMIT must be one full SHA")
        clone = text.index("git clone --depth 1 --branch")
        self.assertLess(clone, text.index(CHECK), "the check must follow the clone it guards")


if __name__ == "__main__":
    unittest.main()
