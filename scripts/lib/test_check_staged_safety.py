# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The pre-commit safety hook stops files that carry credentials, run in a scratch repo."""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

HOOK = Path(__file__).resolve().parents[2] / ".githooks" / "check-staged-safety.sh"


class StagedSafetyTest(unittest.TestCase):
    def setUp(self):
        self.repo = Path(tempfile.mkdtemp(prefix="staged-safety-"))
        self.addCleanup(shutil.rmtree, self.repo, True)
        subprocess.run(["git", "init", "-q"], cwd=self.repo, check=True)

    def check(self, name, content="[]\n"):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        subprocess.run(["git", "add", "--", name], cwd=self.repo, check=True)
        return subprocess.run(["bash", str(HOOK)], cwd=self.repo, capture_output=True, text=True)

    def test_a_load_test_token_cache_is_refused_wherever_it_was_written(self):
        for name in ("loadtest-tokens-http-127-0-0-1-8080.json", "scripts/loadtest-tokens-x.json"):
            got = self.check(name)
            self.assertEqual(got.returncode, 1, name)
            self.assertIn("looks like a credentials file", got.stdout)

    def commit(self, name, content):
        path = self.repo / name
        path.write_text(content)
        git = ["git", "-c", "user.name=t", "-c", "user.email=t@example.invalid"]
        subprocess.run(["git", "add", "--", name], cwd=self.repo, check=True)
        subprocess.run([*git, "commit", "-q", "-m", "x"], cwd=self.repo, check=True)

    def rename(self, old, new):
        subprocess.run(["git", "mv", old, new], cwd=self.repo, check=True)
        return subprocess.run(["bash", str(HOOK)], cwd=self.repo, capture_output=True, text=True)

    def test_a_rename_to_a_credentials_name_is_refused(self):
        self.commit("notes.txt", "line one\nline two\nline three\n")
        got = self.rename("notes.txt", ".env.prod")
        self.assertEqual(got.returncode, 1)
        self.assertIn("looks like a credentials file", got.stdout)

    def test_a_token_added_while_renaming_is_refused(self):
        self.commit("notes.txt", "".join(f"line {i}\n" for i in range(20)))
        (self.repo / "notes.txt").write_text("".join(f"line {i}\n" for i in range(20)) + "ghp_" + "a" * 36 + "\n")
        subprocess.run(["git", "add", "--", "notes.txt"], cwd=self.repo, check=True)
        got = self.rename("notes.txt", "docs.txt")
        self.assertEqual(got.returncode, 1)
        self.assertIn("looks like a private key or API token", got.stdout + got.stderr)

    def test_a_pull_request_range_is_checked_like_the_index(self):
        self.commit("notes.txt", "line one\nline two\nline three\n")
        base = subprocess.run(["git", "rev-parse", "HEAD"], cwd=self.repo, capture_output=True, text=True).stdout.strip()
        subprocess.run(["git", "mv", "notes.txt", ".env.prod"], cwd=self.repo, check=True)
        git = ["git", "-c", "user.name=t", "-c", "user.email=t@example.invalid"]
        subprocess.run([*git, "commit", "-q", "-m", "y"], cwd=self.repo, check=True)
        got = subprocess.run(["bash", str(HOOK), f"{base}...HEAD"], cwd=self.repo, capture_output=True, text=True)
        self.assertEqual(got.returncode, 1)
        self.assertIn("looks like a credentials file", got.stdout)

    def test_an_ordinary_json_file_is_allowed(self):
        self.assertEqual(self.check("loadtest-result-notes.json").returncode, 0)


if __name__ == "__main__":
    unittest.main()
