# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The LLVM apt key is installed only when its fingerprint is the pinned one.

clang 21 for the listener build comes from apt.llvm.org, so the key that signs
that repository is a supply-chain input. The script runs against a fake `curl`
that serves a throwaway key, because the real site is not worth a network call.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from config_source import strip_comments  # noqa: E402

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "docker" / "listener-llvm-key.sh"
FAKE_CURL = """#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-o" ]; then out="$2"; shift; fi
  shift
done
cp "$FAKE_KEY" "$out"
"""
PINNED = re.compile(r"pinned=\"\$\{2:-([0-9A-F]{40})\}\"")


def make_key(home: Path) -> tuple[Path, str]:
    """Generates a throwaway key, returning its armored export and fingerprint."""
    env = {**os.environ, "GNUPGHOME": str(home)}
    subprocess.run(
        ["gpg", "--batch", "--passphrase", "", "--quick-generate-key", "test@example.invalid", "ed25519", "sign", "never"],
        env=env, check=True, capture_output=True,
    )
    armored = subprocess.run(
        ["gpg", "--armor", "--export"], env=env, check=True, capture_output=True
    ).stdout
    listing = subprocess.run(
        ["gpg", "--with-colons", "--list-keys"], env=env, check=True, capture_output=True, text=True
    ).stdout
    fingerprint = next(line.split(":")[9] for line in listing.splitlines() if line.startswith("fpr"))
    key = home / "key.asc"
    key.write_bytes(armored)
    return key, fingerprint


@unittest.skipUnless(shutil.which("gpg"), "needs gpg")
class ListenerLlvmKeyIsPinnedTest(unittest.TestCase):
    def setUp(self) -> None:
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.tmp = Path(scratch.name)
        (self.tmp / "bin").mkdir()
        curl = self.tmp / "bin" / "curl"
        curl.write_text(FAKE_CURL)
        curl.chmod(0o755)
        home = self.tmp / "gnupg"
        home.mkdir(mode=0o700)
        self.addCleanup(
            subprocess.run, ["gpgconf", "--kill", "gpg-agent"],
            env={**os.environ, "GNUPGHOME": str(home)}, capture_output=True,
        )
        self.key, self.fingerprint = make_key(home)

    def install(self, *args: str) -> subprocess.CompletedProcess[str]:
        env = {**os.environ, "PATH": f"{self.tmp / 'bin'}:{os.environ['PATH']}", "FAKE_KEY": str(self.key)}
        return subprocess.run(
            ["bash", str(SCRIPT), str(self.tmp / "llvm.gpg"), *args], env=env, capture_output=True, text=True
        )

    def test_the_pinned_key_is_installed(self) -> None:
        done = self.install(self.fingerprint)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertTrue((self.tmp / "llvm.gpg").stat().st_size > 0)

    def test_a_different_key_is_refused_and_nothing_is_installed(self) -> None:
        done = self.install("0" * 40)
        self.assertNotEqual(done.returncode, 0)
        self.assertIn(self.fingerprint, done.stderr)
        self.assertFalse((self.tmp / "llvm.gpg").exists())

    def test_the_default_pin_is_a_full_fingerprint(self) -> None:
        self.assertRegex(SCRIPT.read_text(), PINNED)


class EveryLlvmKeyFetchIsPinnedTest(unittest.TestCase):
    def test_no_dockerfile_or_workflow_fetches_the_key_on_its_own(self) -> None:
        sources = [*REPO.glob("docker/*.Dockerfile"), *REPO.glob(".github/workflows/*.yml")]
        loose = [p.name for p in sources if "llvm-snapshot.gpg.key" in p.read_text()]
        self.assertEqual(loose, [])

    def test_the_listener_image_and_both_ci_jobs_use_the_script(self) -> None:
        self.assertIn("listener-llvm-key", strip_comments((REPO / "docker/listener.Dockerfile").read_text()))
        ci = strip_comments((REPO / ".github/workflows/listener-ci.yml").read_text())
        # Both jobs run from crates/slimm-listener, so only a workspace-rooted path reaches the script.
        self.assertEqual(ci.count('bash "$GITHUB_WORKSPACE/docker/listener-llvm-key.sh"'), 2)
        self.assertEqual(ci.count("docker/listener-llvm-key.sh"), 2)


if __name__ == "__main__":
    unittest.main()
