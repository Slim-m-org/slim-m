# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""scripts/upload-release-assets.sh against a fake `gh`: retries, and a missing required file fails."""
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "upload-release-assets.sh"

# Fails the first FAIL_FIRST upload calls, then succeeds; logs every call.
FAKE_GH = """#!/usr/bin/env bash
echo "$*" >> "$FAKE_GH_LOG"
if [ "$1 $2" = "release upload" ]; then
  n=$(grep -c '^release upload' "$FAKE_GH_LOG")
  [ "$n" -le "${FAIL_FIRST:-0}" ] && exit 1
fi
exit 0
"""


class UploadReleaseAssets(unittest.TestCase):
    def run_script(self, *patterns, fail_first=0, files=()):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            gh = tmp / "bin" / "gh"
            gh.parent.mkdir()
            gh.write_text(FAKE_GH)
            gh.chmod(gh.stat().st_mode | stat.S_IEXEC)
            for name in files:
                (tmp / name).write_text("x")
            log = tmp / "log"
            log.touch()
            env = {
                **os.environ,
                "PATH": f"{gh.parent}:{os.environ['PATH']}",
                "FAKE_GH_LOG": str(log),
                "FAIL_FIRST": str(fail_first),
                "GITHUB_REPOSITORY": "o/r",
                "UPLOAD_RETRY_SLEEP": "0",
            }
            done = subprocess.run(
                ["bash", str(SCRIPT), "client-v1.2.3", *[str(tmp / p) if not p.startswith("?") else "?" + str(tmp / p[1:]) for p in patterns]],
                env=env, capture_output=True, text=True,
            )
            uploads = [line for line in log.read_text().splitlines() if line.startswith("release upload")]
            return done, uploads

    def test_retries_a_transient_failure_then_succeeds(self):
        done, uploads = self.run_script("a.zip", fail_first=2, files=["a.zip"])
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(len(uploads), 3)

    def test_gives_up_after_the_attempts(self):
        done, uploads = self.run_script("a.zip", fail_first=99, files=["a.zip"])
        self.assertEqual(done.returncode, 1)
        self.assertEqual(len(uploads), 5)

    def test_a_required_pattern_matching_nothing_fails_without_uploading(self):
        done, uploads = self.run_script("a.zip", "*.flatpak", files=["a.zip"])
        self.assertEqual(done.returncode, 1)
        self.assertIn("no file matches", done.stdout)
        self.assertEqual(uploads, [])

    def test_an_optional_pattern_may_match_nothing(self):
        done, uploads = self.run_script("a.zip", "?*.flatpak", files=["a.zip"])
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(len(uploads), 1)
        self.assertNotIn("flatpak", uploads[0])


if __name__ == "__main__":
    unittest.main()
