# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""A called workflow only sees secrets that are passed to it, so every caller of
update-manifest must pass UPDATE_SIGNING_KEY while it is a repository secret.
"""
import unittest
from pathlib import Path

import yaml

WORKFLOWS = Path(__file__).resolve().parents[2] / ".github" / "workflows"
CALLEE = "./.github/workflows/update-manifest.yml"


def _load(name):
    return yaml.safe_load((WORKFLOWS / name).read_text())


class UpdateManifestCallersPassTheKey(unittest.TestCase):
    def test_callee_declares_the_secret(self):
        doc = _load("update-manifest.yml")
        trigger = doc.get("on", doc.get(True))
        self.assertIn("UPDATE_SIGNING_KEY", trigger["workflow_call"]["secrets"])

    def test_every_caller_passes_it(self):
        callers = 0
        for path in sorted(WORKFLOWS.glob("*.yml")):
            for name, job in (_load(path.name).get("jobs") or {}).items():
                if job.get("uses") != CALLEE:
                    continue
                callers += 1
                passed = job.get("secrets")
                self.assertIsInstance(passed, dict, f"{path.name}:{name}")
                self.assertIn("UPDATE_SIGNING_KEY", passed, f"{path.name}:{name}")
        self.assertGreaterEqual(callers, 2)


if __name__ == "__main__":
    unittest.main()
