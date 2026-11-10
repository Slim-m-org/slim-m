# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The Dart api package's live-server tests, run against this stack's server.

live_server_test.dart and compression_interop_test.dart skip themselves unless
SLIMM_TEST_SERVER is set, and nothing else set it, so the Dart client's
register, send, sync, websocket and permessage-deflate behaviour was never
checked against a real server by the Dart suite. They run here with
SLIMM_TEST_SERVER_REQUIRED, so a run that cannot reach the server fails.
"""
import os
import shutil
import subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
API_PACKAGE = os.path.join(ROOT, "client", "packages", "api")
TESTS = ("test/live_server_test.dart", "test/compression_interop_test.dart")
TIMEOUT_SECONDS = 600
TAIL_LINES = 40


def contract_env(server, invite, base=None):
    """[base] (default: this process's environment) plus what the Dart tests read."""
    return {**(os.environ if base is None else base),
            "SLIMM_TEST_SERVER": server,
            "SLIMM_TEST_INVITE": invite,
            "SLIMM_TEST_SERVER_REQUIRED": "1"}


def client_contract_holds(server, admin):
    """Both Dart live-server suites pass against [server]; [admin] mints their invite."""
    dart = shutil.which("dart")
    assert dart, "dart is not on PATH, so the client contract tests cannot run"
    invite = admin.call("POST", "/invites", {})["code"]
    done = subprocess.run(
        [dart, "test", *TESTS], cwd=API_PACKAGE, env=contract_env(server, invite),
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        timeout=TIMEOUT_SECONDS, check=False)
    tail = "\n".join(done.stdout.splitlines()[-TAIL_LINES:])
    assert done.returncode == 0, \
        f"dart test exited {done.returncode}:\n{tail}"
    print("  " + (tail.splitlines() or ["(no output)"])[-1])
