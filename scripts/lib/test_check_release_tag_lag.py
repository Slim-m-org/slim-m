# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Unit coverage for scripts/check-release-tag-lag.sh.

This drives the real script against a real temp git repo rather than a
fake `git`, because the thing under test is a git-history read (which
commit last touched a manifest file, and how old is it) that a stub would
have to reimplement to fake convincingly. Each test builds the exact repo
shape that produced, or did not produce, client 0.32.1's near-miss on
2026-08-06: a manifest bumped by a merge, with or without the matching tag,
at or past the grace window.
"""
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "check-release-tag-lag.sh"


class CheckReleaseTagLagTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.repo = Path(self._tmp.name)
        self._git("init", "-q")
        self._git("config", "user.email", "test@example.invalid")
        self._git("config", "user.name", "test")

    def _git(self, *args):
        subprocess.run(
            ["git", *args], cwd=self.repo, check=True,
            capture_output=True, text=True)

    def _commit_manifest(self, name, version, at_epoch, schema=None):
        body = ({"crates/slimm-server": version}
                if "server" in name else {"client": version})
        if schema is not None:
            body["."] = schema
        (self.repo / name).write_text(json.dumps(body))
        self._git("add", name)
        env_args = [
            f"GIT_AUTHOR_DATE=@{at_epoch} +0000",
            f"GIT_COMMITTER_DATE=@{at_epoch} +0000",
        ]
        subprocess.run(
            ["git", "-c", "commit.gpgsign=false", "commit", "-q", "-m",
             f"chore(main): release {name} {version}"],
            cwd=self.repo, check=True, capture_output=True, text=True,
            env={**_env(), **dict(a.split("=", 1) for a in env_args)})

    def _tag(self, tag):
        self._git("tag", tag)

    def _run(self, now_epoch, grace_seconds=900):
        return subprocess.run(
            ["bash", str(SCRIPT)], cwd=self.repo, capture_output=True,
            text=True,
            env={**_env(), "NOW_EPOCH": str(now_epoch),
                 "GRACE_SECONDS": str(grace_seconds)})

    def test_a_tag_matching_the_manifest_version_is_fine(self):
        self._commit_manifest(".release-please-manifest.server.json",
                               "0.33.1", 1000)
        self._tag("server-v0.33.1")
        result = self._run(now_epoch=1000 + 5000)
        self.assertEqual(result.returncode, 0)

    def test_a_missing_tag_inside_the_grace_window_is_not_stuck(self):
        self._commit_manifest(".release-please-manifest.client.json",
                               "0.32.1", 1000)
        result = self._run(now_epoch=1000 + 60, grace_seconds=900)
        self.assertEqual(result.returncode, 0)
        self.assertIn("not yet cut", result.stdout)
        self.assertIn("within the 900s grace window", result.stdout)

    def test_a_missing_tag_past_the_grace_window_is_stuck(self):
        """The exact shape of client 0.32.1's near-miss: the merge landed,
        the manifest shows the new version, and nothing ever cut the tag."""
        self._commit_manifest(".release-please-manifest.client.json",
                               "0.32.1", 1000)
        result = self._run(now_epoch=1000 + 901, grace_seconds=900)
        self.assertEqual(result.returncode, 1)
        self.assertIn("::error::", result.stdout)
        self.assertIn("client-v0.32.1 was never cut", result.stdout)

    def test_both_packages_are_checked_independently(self):
        self._commit_manifest(".release-please-manifest.server.json",
                               "0.33.1", 1000)
        self._tag("server-v0.33.1")
        self._commit_manifest(".release-please-manifest.client.json",
                               "0.32.1", 1000)
        result = self._run(now_epoch=1000 + 901, grace_seconds=900)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("server-v0.33.1 was never cut", result.stdout)
        self.assertIn("client-v0.32.1 was never cut", result.stdout)

    def test_an_absent_manifest_file_is_not_an_error(self):
        """Neither manifest exists yet in a repo this bare; the script must
        not fail just because a package it looks for is not there."""
        result = self._run(now_epoch=1000)
        self.assertEqual(result.returncode, 0)

    def test_a_stale_tag_from_an_older_version_does_not_hide_a_new_gap(self):
        self._commit_manifest(".release-please-manifest.server.json",
                               "0.33.0", 100)
        self._tag("server-v0.33.0")
        self._commit_manifest(".release-please-manifest.server.json",
                               "0.33.1", 1000)
        result = self._run(now_epoch=1000 + 901, grace_seconds=900)
        self.assertEqual(result.returncode, 1)
        self.assertIn("server-v0.33.1 was never cut", result.stdout)

    def test_a_missing_schema_tag_is_reported_on_its_own(self):
        self._commit_manifest(".release-please-manifest.server.json",
                               "0.76.0", 1000, schema="0.76.0")
        self._tag("server-v0.76.0")
        result = self._run(now_epoch=1000 + 901, grace_seconds=900)
        self.assertEqual(result.returncode, 1)
        self.assertIn("schema-v0.76.0 was never cut", result.stdout)
        self.assertNotIn("server-v0.76.0 was never cut", result.stdout)

    def test_a_present_schema_tag_is_fine(self):
        self._commit_manifest(".release-please-manifest.server.json",
                               "0.76.0", 1000, schema="0.76.0")
        self._tag("server-v0.76.0")
        self._tag("schema-v0.76.0")
        result = self._run(now_epoch=1000 + 901, grace_seconds=900)
        self.assertEqual(result.returncode, 0)


def _env():
    return dict(os.environ)


if __name__ == "__main__":
    unittest.main()
