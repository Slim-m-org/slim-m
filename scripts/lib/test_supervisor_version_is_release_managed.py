# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The supervisor is versioned with the server (decision 0134), and release-please bumps it.

The cargo-workspace plugin only bumps crates that are release-please packages, and a
third package would cut a third tag and GitHub release per version. So the `.` package,
already held to the server's version by linked-versions, names the supervisor's manifest
and its Cargo.lock entry as extra files. Both must move together, or `cargo build
--locked` refuses the release commit.
"""

import json
import tomllib
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
CONFIG = REPO_ROOT / "release-please-config.server.json"
LOCK_PATH = "$.package[?(@.name.value==='slimm-supervisor')].version"


def version_of(manifest: str) -> str:
    return tomllib.loads((REPO_ROOT / manifest).read_text())["package"]["version"]


class SupervisorVersionIsReleaseManagedTest(unittest.TestCase):
    def test_the_root_package_bumps_the_manifest_and_the_lock_entry(self):
        files = json.loads(CONFIG.read_text())["packages"]["."]["extra-files"]
        wanted = [
            {"type": "toml", "path": "crates/slimm-supervisor/Cargo.toml", "jsonpath": "$.package.version"},
            {"type": "toml", "path": "Cargo.lock", "jsonpath": LOCK_PATH},
        ]
        for entry in wanted:
            self.assertIn(entry, files, f"release-please no longer bumps {entry['path']} for the supervisor")

    def test_the_supervisor_has_the_servers_version_everywhere(self):
        server = version_of("crates/slimm-server/Cargo.toml")
        self.assertEqual(version_of("crates/slimm-supervisor/Cargo.toml"), server)
        lock = tomllib.loads((REPO_ROOT / "Cargo.lock").read_text())
        locked = [p["version"] for p in lock["package"] if p["name"] == "slimm-supervisor"]
        self.assertEqual(locked, [server])


if __name__ == "__main__":
    unittest.main()
