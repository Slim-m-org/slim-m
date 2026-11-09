# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""e2e-stack.sh's functions, driven one at a time against a stub docker and no real stack."""
import http.server
import os
import shutil
import socket
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

STACK = Path(__file__).resolve().parents[1] / "e2e-stack.sh"
DOCKER_STUB = """#!/bin/sh
echo "$@" >> "$DOCKER_STUB_LOG"
if [ "$1" = logs ]; then echo "stub livekit: could not bind"; fi
exit 0
"""


def closed_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


class StackScriptCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="stack-script-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.work = self.tmp / "work"
        (self.work / "pids").mkdir(parents=True)
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        (bin_dir / "docker").write_text(DOCKER_STUB)
        (bin_dir / "docker").chmod(0o755)
        self.docker_log = self.tmp / "docker.log"
        self.env = {
            **os.environ,
            "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
            "DOCKER_STUB_LOG": str(self.docker_log),
            "E2E_WORK": str(self.work),
            "E2E_LK_CONTAINER": "slimm-e2e-script-test",
            "E2E_SFU_WAIT_SECONDS": "1",
        }

    def call(self, function, **env):
        return subprocess.run(
            ["bash", "-c", f'source "{STACK}"; {function}'],
            env={**self.env, **env}, capture_output=True, text=True, timeout=60)


class StopPidFileTest(StackScriptCase):
    def pid_file(self, name, content):
        path = self.work / "pids" / f"{name}.pid"
        path.write_text(str(content))
        return path

    def spawn(self, program="sleep"):
        proc = subprocess.Popen([program, "60"])
        self.addCleanup(proc.wait)
        self.addCleanup(proc.kill)
        return proc

    def test_a_process_that_only_inherited_the_pid_is_left_alone(self):
        stranger = self.spawn()
        path = self.pid_file("api", stranger.pid)
        result = self.call("stop_pid_file api slimm-server")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIsNone(stranger.poll())
        self.assertFalse(path.exists())

    def test_the_server_it_started_is_stopped(self):
        binary = self.tmp / "slimm-server"
        shutil.copy(shutil.which("sleep"), binary)
        ours = self.spawn(str(binary))
        path = self.pid_file("api", ours.pid)
        self.assertEqual(self.call("stop_pid_file api slimm-server").returncode, 0)
        ours.wait(timeout=10)
        self.assertFalse(path.exists())

    def test_a_dead_or_garbled_pid_file_is_just_removed(self):
        for content in ("999999999", "not a pid", ""):
            path = self.pid_file("web", content)
            result = self.call("stop_pid_file web e2e_web_server.py")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(path.exists(), content)


class StartSfuTest(StackScriptCase):
    def serve(self):
        class Quiet(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Quiet)
        self.addCleanup(server.server_close)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.shutdown)
        return server.server_address[1]

    def test_every_published_port_is_loopback_only(self):
        result = self.call("start_sfu", E2E_LK_PORT=str(self.serve()))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        run = next(line.split() for line in self.docker_log.read_text().splitlines()
                   if line.startswith("run "))
        published = [run[i + 1] for i, word in enumerate(run) if word == "-p"]
        self.assertEqual(len(published), 3)
        for spec in published:
            self.assertTrue(spec.startswith("127.0.0.1:"), spec)

    def test_a_container_that_never_answers_fails_with_its_logs(self):
        result = self.call("start_sfu", E2E_LK_PORT=str(closed_port()))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("livekit never came up", result.stdout)
        self.assertIn("stub livekit: could not bind", result.stdout)


class SourcingTest(StackScriptCase):
    def test_sourcing_runs_nothing_and_running_it_still_dispatches(self):
        self.assertEqual(self.call("true").stdout, "")
        result = subprocess.run(["bash", str(STACK), "bogus"], env=self.env,
                                capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 2)
        self.assertIn("usage:", result.stderr)


if __name__ == "__main__":
    unittest.main()
