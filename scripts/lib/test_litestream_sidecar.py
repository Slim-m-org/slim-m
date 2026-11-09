# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The litestream profile refuses an empty bucket and reports a replica that falls behind.

`deploy/litestream/sidecar.sh` runs against a fake `litestream` that prints the
`generations` table the real 0.3.14 prints (checked against the pinned image),
so the parsing is exercised without a bucket.
"""

from __future__ import annotations

import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

from test_compose_hardening import service_blocks

REPO = Path(__file__).resolve().parents[2]
SIDECAR = REPO / "deploy" / "litestream" / "sidecar.sh"
COMPOSE = REPO / "docker-compose.yml"

FAKE_LITESTREAM = """#!/bin/sh
echo "$@" >> "$FAKE_CALLS"
if [ "$1" = "generations" ]; then
  cat "$FAKE_TABLE"
  exit "${FAKE_EXIT:-0}"
fi
"""
HEADER = "name  generation        lag    start                 end\n"
ERROR = 'time=2026-11-09T21:31:29.287Z level=ERROR msg="cannot list generations" error="NoSuchBucket"\n'


def row(generation: str, lag: str, end: str) -> str:
    return f"s3    {generation}  {lag}  2026-11-09T21:00:00Z  {end}\n"


class SidecarTest(unittest.TestCase):
    def setUp(self) -> None:
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.tmp = Path(scratch.name)
        (self.tmp / "bin").mkdir()
        fake = self.tmp / "bin" / "litestream"
        fake.write_text(FAKE_LITESTREAM)
        fake.chmod(0o755)
        self.calls = self.tmp / "calls.txt"
        self.calls.write_text("")

    def run_sidecar(self, *args: str, table: str = "", exit_code: int = 0, env: dict[str, str] | None = None):
        (self.tmp / "table.txt").write_text(table)
        full = {
            **os.environ,
            "PATH": f"{self.tmp / 'bin'}:{os.environ['PATH']}",
            "FAKE_CALLS": str(self.calls),
            "FAKE_TABLE": str(self.tmp / "table.txt"),
            "FAKE_EXIT": str(exit_code),
            **(env or {}),
        }
        return subprocess.run(["sh", str(SIDECAR), *args], env=full, capture_output=True, text=True)

    def health(self, table: str, limit: str = "300", exit_code: int = 0):
        return self.run_sidecar("health", limit, table=table, exit_code=exit_code)

    def test_a_replica_within_the_limit_is_healthy(self) -> None:
        done = self.health(HEADER + row("aaaa", "42s", "2026-11-09T21:29:14Z"))
        self.assertEqual(done.returncode, 0, done.stderr)

    def test_a_replica_behind_the_limit_is_unhealthy_and_says_how_far(self) -> None:
        done = self.health(HEADER + row("aaaa", "6m3s", "2026-11-09T21:29:14Z"))
        self.assertEqual(done.returncode, 1)
        self.assertIn("363 seconds behind", done.stderr)

    def test_hours_count(self) -> None:
        done = self.health(HEADER + row("aaaa", "1h2m3s", "2026-11-09T21:29:14Z"))
        self.assertEqual(done.returncode, 1)
        self.assertIn("3723 seconds behind", done.stderr)

    def test_a_negative_or_sub_second_lag_is_zero(self) -> None:
        for lag in ("-6ms", "932ms", "0s", "12us"):
            done = self.health(HEADER + row("aaaa", lag, "2026-11-09T21:29:14Z"), limit="0")
            self.assertEqual(done.returncode, 0, f"{lag}: {done.stderr}")

    def test_only_the_newest_generation_counts(self) -> None:
        table = (
            HEADER
            + row("old", "9h2m3s", "2026-11-08T01:00:00Z")
            + row("new", "2s", "2026-11-09T21:29:14Z")
        )
        self.assertEqual(self.health(table).returncode, 0)
        newest_behind = HEADER + row("old", "1s", "2026-11-08T01:00:00Z") + row("new", "7m", "2026-11-09T21:29:14Z")
        self.assertEqual(self.health(newest_behind).returncode, 1)

    def test_no_generation_is_unhealthy_and_shows_the_listing_error(self) -> None:
        done = self.health(ERROR + HEADER)
        self.assertEqual(done.returncode, 1)
        self.assertIn("no replica generation yet", done.stderr)
        self.assertIn("NoSuchBucket", done.stderr)

    def test_a_log_line_is_not_mistaken_for_a_generation(self) -> None:
        self.assertEqual(self.health(HEADER + ERROR).returncode, 1)

    def test_a_failing_litestream_is_unhealthy(self) -> None:
        done = self.health(HEADER + row("aaaa", "1s", "2026-11-09T21:29:14Z"), exit_code=1)
        self.assertNotEqual(done.returncode, 0)

    def test_start_refuses_an_empty_bucket_and_never_runs_litestream(self) -> None:
        env = {"LITESTREAM_S3_BUCKET": "", "LITESTREAM_ACCESS_KEY_ID": "a", "LITESTREAM_SECRET_ACCESS_KEY": "b"}
        done = self.run_sidecar("start", env=env)
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("LITESTREAM_S3_BUCKET", done.stderr)
        self.assertEqual(self.calls.read_text(), "")

    def test_start_refuses_an_empty_key(self) -> None:
        for missing in ("LITESTREAM_ACCESS_KEY_ID", "LITESTREAM_SECRET_ACCESS_KEY"):
            env = {"LITESTREAM_S3_BUCKET": "b", "LITESTREAM_ACCESS_KEY_ID": "a", "LITESTREAM_SECRET_ACCESS_KEY": "b"}
            env[missing] = ""
            done = self.run_sidecar("start", env=env)
            self.assertNotEqual(done.returncode, 0, missing)
            self.assertIn(missing, done.stderr)

    def test_start_replicates_with_the_mounted_config(self) -> None:
        env = {"LITESTREAM_S3_BUCKET": "b", "LITESTREAM_ACCESS_KEY_ID": "a", "LITESTREAM_SECRET_ACCESS_KEY": "b"}
        done = self.run_sidecar("start", env=env)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(self.calls.read_text().strip(), "replicate -config /sidecar/litestream.yml")

    def test_an_unknown_command_is_a_usage_error(self) -> None:
        self.assertEqual(self.run_sidecar("bogus").returncode, 2)


class ComposeWiringTest(unittest.TestCase):
    def setUp(self) -> None:
        self.text = COMPOSE.read_text()
        self.body = service_blocks(self.text)["litestream"]

    def test_the_service_starts_through_the_sidecar_and_is_health_checked_by_it(self) -> None:
        self.assertIn('entrypoint: ["/bin/sh", "/sidecar/sidecar.sh", "start"]', self.body)
        self.assertIn('test: ["CMD", "/bin/sh", "/sidecar/sidecar.sh", "health"]', self.body)

    def test_the_sidecar_files_are_mounted_from_the_repo(self) -> None:
        self.assertIn("./deploy/litestream:/sidecar:ro", self.body)
        self.assertTrue(SIDECAR.exists())
        self.assertTrue((SIDECAR.parent / "litestream.yml").exists())

    def test_the_config_reads_the_variables_the_service_passes(self) -> None:
        config = (SIDECAR.parent / "litestream.yml").read_text()
        for name in set(re.findall(r"\$\{(\w+)\}", config)):
            self.assertRegex(self.body, rf"\n\s+{name}: ", name)

    def test_no_profile_gated_service_requires_a_variable_in_the_compose_file(self) -> None:
        """Compose interpolates every service, profile or not, so `:?` breaks `docker compose up` for everyone."""
        for name, body in service_blocks(self.text).items():
            if "profiles:" in body:
                self.assertNotRegex(body, r"\$\{\w+:\?", name)


if __name__ == "__main__":
    unittest.main()
