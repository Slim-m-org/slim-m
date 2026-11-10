# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The call-audio listener is its own cargo workspace, so cargo-deny only sees it when told to.

The root `Cargo.toml` excludes `crates/slimm-listener`, which carries a lockfile
of its own. An argument-less `cargo deny` run at the repo root never reads that
lockfile, so each gate that claims to cover every Rust crate has to name the
listener manifest explicitly.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
LISTENER_MANIFEST = "manifest-path: crates/slimm-listener/Cargo.toml"


def workflow(name: str) -> str:
    return (REPO / ".github/workflows" / name).read_text()


def deny_steps(text: str, command: str) -> int:
    """Counts cargo-deny steps that run `command`, however the `with:` keys are ordered."""
    steps = re.split(r"\n      - ", text)
    return sum(
        1
        for step in steps
        if "EmbarkStudios/cargo-deny-action" in step
        and re.search(rf"command: check {command}\b", step)
    )


def listener_steps(text: str, command: str) -> int:
    steps = re.split(r"\n      - ", text)
    return sum(
        1
        for step in steps
        if "EmbarkStudios/cargo-deny-action" in step
        and LISTENER_MANIFEST in step
        and re.search(rf"command: check {command}\b", step)
    )


class CargoDenyCoversTheListenerTest(unittest.TestCase):
    def test_the_license_gate_scans_the_listener_lockfile(self) -> None:
        text = workflow("licenses.yml")
        self.assertEqual(listener_steps(text, "licenses"), 1)
        self.assertEqual(deny_steps(text, "licenses"), 2)

    def test_the_license_gate_runs_when_only_the_listener_lockfile_changes(self) -> None:
        self.assertIn('"crates/slimm-listener/Cargo.lock"', workflow("licenses.yml"))

    def test_the_advisory_watchdog_scans_the_listener_lockfile(self) -> None:
        text = workflow("advisory-watchdog.yml")
        self.assertEqual(listener_steps(text, "advisories"), 1)
        self.assertEqual(deny_steps(text, "advisories"), 2)

    def test_a_listener_finding_reaches_the_issue(self) -> None:
        text = workflow("advisory-watchdog.yml")
        self.assertIn("steps.scan_listener.outcome", text)
        self.assertIn("ADVISORY_LOCKFILES", text)

    def test_the_listener_may_carry_its_own_license(self) -> None:
        deny = (REPO / "deny.toml").read_text()
        self.assertRegex(deny, r'name = "slimm-listener"\nallow = \["LicenseRef-PolyForm')


if __name__ == "__main__":
    unittest.main()
