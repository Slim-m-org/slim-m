# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Every fedora and ubuntu image a workflow, action, script or Dockerfile runs is pinned by digest.

The release rpm, the COPR source rpm and the ViSQOL image are built in these, and
a moved tag would change what they build with no commit to show for it. Comment
lines are skipped, so prose may still say `fedora:44`.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GLOBS = [
    ".github/workflows/*.yml",
    ".github/actions/*/action.yml",
    "scripts/*.sh",
    "scripts/lib/*.Dockerfile",
    "docker/*.Dockerfile",
]
IMAGE = re.compile(r"(?<![\w./-])((?:fedora|ubuntu):[\w.]+)(?!\w)(@sha256:[0-9a-f]{64})?")
RUNNER_LABEL = re.compile(r"ubuntu:\d")


def unpinned(text: str) -> list[str]:
    """Each fedora or ubuntu image reference outside a comment that carries no digest."""
    found = []
    for line in text.splitlines():
        if line.lstrip().startswith("#"):
            continue
        for match in IMAGE.finditer(line):
            if match.group(2) is None:
                found.append(match.group(1))
    return found


class ReleaseImagesArePinnedTest(unittest.TestCase):
    def test_no_image_reference_is_floating(self):
        paths = [p for g in GLOBS for p in sorted(ROOT.glob(g)) if p.name != Path(__file__).name]
        self.assertTrue(paths)
        for path in paths:
            with self.subTest(file=str(path.relative_to(ROOT))):
                self.assertEqual(unpinned(path.read_text()), [])

    def test_a_bare_tag_is_seen(self):
        self.assertEqual(unpinned("    container: fedora:44\n"), ["fedora:44"])
        self.assertEqual(unpinned("FROM ubuntu:22.04\n"), ["ubuntu:22.04"])
        self.assertEqual(unpinned("docker run --rm fedora:44 bash\n"), ["fedora:44"])

    def test_a_digest_pin_is_accepted(self):
        pin = "@sha256:" + "a" * 64
        self.assertEqual(unpinned(f"    container: fedora:44{pin}\n"), [])
        self.assertEqual(unpinned(f"FROM ubuntu:22.04{pin}\n"), [])

    def test_a_comment_may_name_the_tag(self):
        self.assertEqual(unpinned("# its own fedora:44 container\n"), [])

    def test_bazelisk_is_verified(self):
        dockerfile = (ROOT / "scripts" / "lib" / "visqol.Dockerfile").read_text()
        add = next(line for line in dockerfile.splitlines() if line.startswith("ADD") and "bazelisk" in line)
        self.assertRegex(add, r"--checksum=sha256:[0-9a-f]{64}")


if __name__ == "__main__":
    unittest.main()
