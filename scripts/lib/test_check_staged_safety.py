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

    def test_an_ordinary_json_file_is_allowed(self):
        self.assertEqual(self.check("loadtest-result-notes.json").returncode, 0)


if __name__ == "__main__":
    unittest.main()
