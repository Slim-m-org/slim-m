# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The push-time schema gate diffs a server release against the last schema tag, not just its parent.

Against the parent alone, a breaking change merged earlier in the release window
shipped with a green gate.
"""
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

from test_windows_builds_do_not_run_under_bash import jobs

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "schema-gate-base.sh"
SCHEMA = (ROOT / ".github" / "workflows" / "schema-ci.yml").read_text()


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", *args],
        cwd=repo, capture_output=True, text=True, check=True,
    )
    return result.stdout.strip()


MANIFEST = ".release-please-manifest.server.json"


def commit(repo: Path, subject: str, touching: str = "") -> str:
    if touching:
        (repo / touching).write_text(subject)
        git(repo, "add", touching)
    git(repo, "commit", "--allow-empty", "-m", subject)
    return git(repo, "rev-parse", "HEAD")


def base_of(repo: Path):
    return subprocess.run([str(SCRIPT)], cwd=repo, capture_output=True, text=True)


class SchemaGateBaseTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.repo = Path(self._tmp.name)
        git(self.repo, "init", "-q", "-b", "main")

    def test_an_ordinary_commit_is_diffed_against_its_parent(self):
        commit(self.repo, "feat: first")
        commit(self.repo, "fix: second")
        self.assertEqual(base_of(self.repo).stdout.strip(), "HEAD~1")

    def test_a_server_release_is_diffed_against_the_newest_schema_tag(self):
        commit(self.repo, "feat: old")
        git(self.repo, "tag", "schema-v0.1.0")
        commit(self.repo, "feat: breaking change")
        commit(self.repo, "fix: later")
        commit(self.repo, "chore: release main (#1)", MANIFEST)
        result = base_of(self.repo)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "schema-v0.1.0")

    def test_the_newest_of_several_tags_wins(self):
        commit(self.repo, "feat: a")
        git(self.repo, "tag", "schema-v0.1.0")
        commit(self.repo, "feat: b")
        git(self.repo, "tag", "schema-v0.2.0")
        commit(self.repo, "chore: release main (#2)", MANIFEST)
        self.assertEqual(base_of(self.repo).stdout.strip(), "schema-v0.2.0")

    def test_a_release_commit_is_not_its_own_base(self):
        commit(self.repo, "feat: a")
        commit(self.repo, "chore: release main (#2)", MANIFEST)
        git(self.repo, "tag", "schema-v0.2.0")
        self.assertNotEqual(base_of(self.repo).returncode, 0)

    def test_the_subject_does_not_decide_what_a_release_is(self):
        commit(self.repo, "feat: a")
        git(self.repo, "tag", "schema-v0.1.0")
        commit(self.repo, "chore(main): release server 0.2.0 (#5)")
        self.assertEqual(base_of(self.repo).stdout.strip(), "HEAD~1")

    def test_a_client_release_keeps_the_parent_base(self):
        commit(self.repo, "feat: a")
        git(self.repo, "tag", "schema-v0.1.0")
        commit(self.repo, "chore(main): release client 0.5.0 (#3)", ".release-please-manifest.client.json")
        self.assertEqual(base_of(self.repo).stdout.strip(), "HEAD~1")

    def test_a_release_with_no_tag_behind_it_fails_closed(self):
        commit(self.repo, "feat: a")
        commit(self.repo, "chore: release main (#4)", MANIFEST)
        result = base_of(self.repo)
        self.assertEqual(result.returncode, 1)
        self.assertIn("schema-v*", result.stderr)


class SchemaCiUsesTheScriptTest(unittest.TestCase):
    def setUp(self):
        self.gate = jobs(SCHEMA)["breaking-change-gate-main"]

    def test_the_gate_asks_the_script_for_its_base(self):
        self.assertIn("scripts/schema-gate-base.sh", self.gate)
        base = re.search(r"^\s+base:\s*(.+)$", self.gate, re.M).group(1)
        self.assertIn("steps.base.outputs.rev", base)
        self.assertNotIn("HEAD~1", base)

    def test_the_checkout_has_the_history_and_tags_to_find_the_tag(self):
        self.assertRegex(self.gate, r"fetch-depth:\s*0")


if __name__ == "__main__":
    unittest.main()
