# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Unit coverage for scripts/release-latest-allowed.sh.

Drives the real script through `bash` against throwaway git repositories,
including a replay of the 2026-10-14 incident: a release cut one commit
behind a merged migration must not move :latest.
"""
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent
SCRIPT = SCRIPTS / "release-latest-allowed.sh"


class ReleaseLatestAllowedTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.repo = Path(self._tmp.name)
        self._git("init", "-q", "-b", "main")
        self._git("config", "user.email", "test@example.invalid")
        self._git("config", "user.name", "test")
        # The script reads the shared path list next to itself; copy both so the repo is self-contained.
        (self.repo / "scripts").mkdir()
        for name in ("release-latest-allowed.sh", "server-image-paths.txt"):
            (self.repo / "scripts" / name).write_text((SCRIPTS / name).read_text())
        self._commit("crates/slimm-server/src/lib.rs", "fn main() {}\n", "server")

    def _git(self, *args):
        return subprocess.run(
            ["git", *args], cwd=self.repo, check=True, capture_output=True, text=True
        ).stdout.strip()

    def _commit(self, path, text, message):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
        self._git("add", "-A")
        self._git("commit", "-q", "-m", message)
        return self._git("rev-parse", "HEAD")

    def _run(self, release, main):
        result = subprocess.run(
            ["bash", str(self.repo / "scripts" / "release-latest-allowed.sh"), release, main],
            cwd=self.repo, capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip(), result.stderr

    def test_a_release_at_the_tip_of_main_may_move_latest(self):
        release = self._git("rev-parse", "HEAD")
        self.assertEqual(self._run(release, "main")[0], "true")

    def test_main_ahead_only_outside_the_server_may_move_latest(self):
        release = self._git("rev-parse", "HEAD")
        self._commit("perf/baseline.json", "{}\n", "perf baseline")
        self._commit("client/packages/app/lib/main.dart", "void main() {}\n", "client")
        self.assertEqual(self._run(release, "main")[0], "true")

    def test_a_release_behind_a_merged_migration_must_not_move_latest(self):
        release = self._git("rev-parse", "HEAD")
        self._commit(
            "crates/slimm-server/migrations/0107_temporary_voice_rooms.sql",
            "ALTER TABLE channels ADD COLUMN room_owner_id BLOB;\n",
            "temporary voice rooms",
        )
        answer, warning = self._run(release, "main")
        self.assertEqual(answer, "false")
        self.assertIn("::warning::", warning)

    def test_every_server_path_counts(self):
        for path in ("Cargo.lock", "rust-toolchain.toml", "docker/server.Dockerfile", ".sqlx/query-x.json"):
            with self.subTest(path=path):
                release = self._git("rev-parse", "HEAD")
                self._commit(path, f"{path}\n", f"touch {path}")
                self.assertEqual(self._run(release, "main")[0], "false")

    def test_an_unknown_ref_fails_closed(self):
        answer, warning = self._run("0" * 40, "main")
        self.assertEqual(answer, "false")
        self.assertIn("cannot compare", warning)


if __name__ == "__main__":
    unittest.main()
