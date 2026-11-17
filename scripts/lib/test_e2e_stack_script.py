# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""e2e-stack.sh's functions, driven one at a time against a stub docker and no real stack."""
import http.server
import os
import re
import shutil
import socket
import subprocess
import tempfile
import threading
import unittest
import urllib.request
from pathlib import Path

STACK = Path(__file__).resolve().parents[1] / "e2e-stack.sh"
DOCKER_STUB = """#!/bin/sh
echo "$@" >> "$DOCKER_STUB_LOG"
if [ "$1" = logs ]; then echo "stub livekit: could not bind"; fi
exit 0
"""


SERVER_STUB = """#!/usr/bin/env python3
import http.server, os


class Health(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *args):
        pass


host = os.environ.get("SLIMM_BIND_ADDRESS", "0.0.0.0")
server = http.server.HTTPServer((host, int(os.environ["SLIMM_PORT"])), Health)
open(os.environ["SERVER_STUB_BOUND"], "w").write(server.server_address[0])
server.serve_forever()
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

    def test_the_sfu_posts_its_webhook_to_the_server_through_the_bridge(self):
        port = str(self.serve())
        self.call("start_sfu", E2E_LK_PORT=port, E2E_API_PORT="18095", WEBHOOK_GATEWAY="172.17.0.1")
        log = self.docker_log.read_text()
        self.assertIn("--add-host=host.docker.internal:host-gateway", log)
        self.assertIn("'http://host.docker.internal:18095/voice/webhook'", log)

    def test_no_bridge_means_no_webhook(self):
        self.call("start_sfu", E2E_LK_PORT=str(self.serve()))
        self.assertNotIn("webhook", self.docker_log.read_text())

    def test_a_container_that_never_answers_fails_with_its_logs(self):
        result = self.call("start_sfu", E2E_LK_PORT=str(closed_port()))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("livekit never came up", result.stdout)
        self.assertIn("stub livekit: could not bind", result.stdout)


class WebhookRelayTest(unittest.TestCase):
    RELAY = Path(__file__).resolve().parent / "e2e_webhook_relay.py"

    def test_it_refuses_to_listen_on_every_interface(self):
        result = subprocess.run(["python3", str(self.RELAY), "0.0.0.0", "1", "2"],
                                capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("every interface", result.stderr)

    def test_it_carries_a_request_to_the_loopback_server(self):
        class Echo(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"]))
                self.send_response(200)
                self.end_headers()
                self.wfile.write(body[::-1])

            def log_message(self, *args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Echo)
        self.addCleanup(server.server_close)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.shutdown)
        listen = closed_port()
        relay = subprocess.Popen(["python3", str(self.RELAY), "127.0.0.1", str(listen),
                                  str(server.server_address[1])])
        self.addCleanup(relay.wait)
        self.addCleanup(relay.kill)
        for _ in range(50):
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{listen}/voice/webhook",
                                            data=b"joined", timeout=2) as response:
                    self.assertEqual(response.read(), b"denioj")
                    return
            except OSError:
                relay.poll()
                self.assertIsNone(relay.returncode)
                threading.Event().wait(0.1)
        self.fail("the relay never answered")


class SpeakerDetectionTest(unittest.TestCase):
    """The e2e SFU decides who is speaking exactly the way prod's does."""

    @staticmethod
    def _pairs(text):
        return dict(p.strip().split(": ") for p in text.split(",") if p.strip())

    def test_matches_docker_compose_voice(self):
        script = Path(STACK).read_text()
        default = re.search(r'LK_AUDIO="\$\{E2E_LK_AUDIO:-([^}]*)\}"', script).group(1)
        compose = (Path(STACK).parents[1] / "docker-compose.voice.yml").read_text()
        block = re.search(r"\n( +)audio:\n((?:\1 +\w+: \S+\n)+)", compose).group(2)
        prod = dict(line.strip().split(": ") for line in block.splitlines())
        self.assertEqual(self._pairs(default), prod)


class StartServerTest(StackScriptCase):
    def test_the_server_listens_on_loopback_only(self):
        release = self.tmp / "target" / "release"
        release.mkdir(parents=True)
        (release / "slimm-server").write_text(SERVER_STUB)
        (release / "slimm-server").chmod(0o755)
        bound = self.tmp / "bound.txt"
        self.addCleanup(lambda: self.call("stop_pid_file api slimm-server"))
        result = self.call(
            "start_server", CARGO_TARGET_DIR=str(self.tmp / "target"), E2E_SKIP_SERVER_BUILD="1",
            E2E_API_PORT=str(closed_port()), SERVER_STUB_BOUND=str(bound))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(bound.read_text(), "127.0.0.1")


class SourcingTest(StackScriptCase):
    def test_sourcing_runs_nothing_and_running_it_still_dispatches(self):
        self.assertEqual(self.call("true").stdout, "")
        result = subprocess.run(["bash", str(STACK), "bogus"], env=self.env,
                                capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 2)
        self.assertIn("usage:", result.stderr)


if __name__ == "__main__":
    unittest.main()
