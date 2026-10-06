# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""perf/measure-idle-rss.sh must exit 0 after a good run and non-zero after a failed measurement."""
import socket
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "perf" / "measure-idle-rss.sh"

STUB_SERVER = """#!/usr/bin/env python3
import http.server, os
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(os.environ["SLIMM_PORT"])), H).serve_forever()
"""


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def run(binary_text: str, *extra: str) -> subprocess.CompletedProcess:
    with tempfile.TemporaryDirectory() as tmp:
        binary = Path(tmp) / "fakebin"
        binary.write_text(binary_text)
        binary.chmod(0o755)
        env = {"PATH": "/usr/bin:/bin", "SLIMM_RSS_HEALTH_ATTEMPTS": "3"}
        return subprocess.run(
            ["bash", str(SCRIPT), "--bin", str(binary), "--port-glibc", str(free_port()), *extra],
            env=env, capture_output=True, text=True, timeout=60,
        )


class MeasureIdleRssTest(unittest.TestCase):
    def test_a_good_glibc_only_run_exits_zero(self):
        result = run(STUB_SERVER, "--skip-musl")
        self.assertIn("idle_rss_glibc", result.stdout)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_a_server_that_never_answers_fails_the_run(self):
        result = run("#!/bin/sh\nexit 1\n", "--skip-musl")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("timed out waiting", result.stderr)

    def test_a_dead_server_prints_no_empty_metric_lines(self):
        result = run("#!/bin/sh\nexit 1\n", "--skip-musl")
        self.assertNotIn("idle_rss_glibc =  kB", result.stdout)
        self.assertNotIn("fatal", result.stderr)


if __name__ == "__main__":
    unittest.main()
