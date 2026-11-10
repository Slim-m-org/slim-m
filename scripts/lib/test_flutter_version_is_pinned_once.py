# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Every workflow, action and Dockerfile pins the same Flutter version.

The pin is spelled in many places and nothing else connects them, so missing
one leaves a job on a different Flutter than the rest and nothing fails.
`docker/web.Dockerfile` cannot read a composite action, which is why this is a
test rather than a shared action.
"""
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from config_source import strip_comments  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
PIN = re.compile(r"flutter-version:\s*['\"]?([\w.+-]+)['\"]?\s*$", re.M)
ARG = re.compile(r"^ARG FLUTTER_VERSION=(\S+)\s*$", re.M)
COMMIT = re.compile(r"^ARG FLUTTER_COMMIT=([0-9a-f]{40})\s*$", re.M)
CHECK = 'test "$(git -C /opt/flutter rev-parse HEAD)" = "${FLUTTER_COMMIT}"'


def pins() -> dict[str, list[str]]:
    found = {}
    sources = [*sorted((ROOT / ".github").rglob("*.yml"))]
    for path in sources:
        versions = PIN.findall(strip_comments(path.read_text()))
        if versions:
            found[str(path.relative_to(ROOT))] = versions
    for path in sorted((ROOT / "docker").glob("*.Dockerfile")):
        versions = ARG.findall(strip_comments(path.read_text()))
        if versions:
            found[str(path.relative_to(ROOT))] = versions
    return found


def checks_the_clone(dockerfile: str) -> bool:
    """Whether a live line verifies the cloned Flutter's commit after the clone it guards."""
    code = strip_comments(dockerfile)
    clone = code.find("git clone --depth 1 --branch")
    return clone != -1 and code.find(CHECK) > clone


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
        self.assertEqual(len(COMMIT.findall(strip_comments(text))), 1, "FLUTTER_COMMIT must be one full SHA")
        self.assertTrue(checks_the_clone(text), "a live line must check the commit after the clone it guards")

    def test_a_check_commented_out_of_the_run_does_not_count(self):
        text = (ROOT / "docker" / "web.Dockerfile").read_text()
        self.assertIn(CHECK, text)
        for commented in (f"    # && {CHECK}", f"RUN true # && {CHECK}"):
            with self.subTest(commented=commented):
                tampered = re.sub(rf"^.*{re.escape(CHECK)}.*$", commented, text, flags=re.M)
                self.assertFalse(checks_the_clone(tampered))


if __name__ == "__main__":
    unittest.main()
