# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""schema/openapi.yaml's `info.version` must track the server's own version.

Nothing generates this field or checks it against anything else: redocly
lint only validates that it is a string, and the openapi-vs-router contract
test in crates/slimm-server/tests/it_infra/openapi_contract.rs compares routes, never
this value. That let it sit at 0.18.5 against a 0.37.0 server until PR #596
hand-corrected it to 0.37.0 - and with nothing to hold the correction in
place, it drifted straight back: by the time this test was added the server
had moved on to 0.45.2 while this field still read 0.37.0.

The server's own Cargo.toml is the natural source of truth (`crates/slimm-server`
is what schema/openapi.yaml documents), so this ties the field to that rather
than to the client's pubspec.yaml, which versions a different artifact on its
own release cadence.
"""

import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
CARGO_TOML = REPO_ROOT / "crates" / "slimm-server" / "Cargo.toml"
OPENAPI_YAML = REPO_ROOT / "schema" / "openapi.yaml"


def server_cargo_version() -> str:
    """The `[package]` version, not any `workspace = true` dependency line."""
    text = CARGO_TOML.read_text()
    block = re.search(r"\[package\]([\s\S]*?)(\n\[|\Z)", text)
    if not block:
        raise AssertionError(f"could not find a [package] section in {CARGO_TOML}")
    match = re.search(r'^version\s*=\s*"([^"]+)"', block.group(1), re.M)
    if not match:
        raise AssertionError(f"could not find a version in {CARGO_TOML}'s [package]")
    return match.group(1)


def openapi_info_version() -> str:
    text = OPENAPI_YAML.read_text()
    block = re.search(r"^info:\n([\s\S]*?)(?=\n\S|\Z)", text, re.M)
    if not block:
        raise AssertionError(f"could not find an info: block in {OPENAPI_YAML}")
    match = re.search(r"^\s+version:\s*([0-9][^\s#]*)", block.group(1), re.M)
    if not match:
        raise AssertionError(f"could not find info.version in {OPENAPI_YAML}")
    return match.group(1)


class OpenapiVersionMatchesCargoTest(unittest.TestCase):
    def test_openapi_info_version_matches_server_cargo_version(self):
        self.assertEqual(
            openapi_info_version(),
            server_cargo_version(),
            "schema/openapi.yaml's info.version no longer matches "
            "crates/slimm-server/Cargo.toml's [package] version - bump "
            "info.version alongside the server release that changes it",
        )


if __name__ == "__main__":
    unittest.main()
