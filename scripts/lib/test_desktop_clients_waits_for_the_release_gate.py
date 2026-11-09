# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""desktop-clients attaches release assets, so it waits for the same gate release.yml does.

It starts the moment a client-v* tag is pushed, in parallel with release.yml's
verify-client-ci. Without its own call, a red release commit still got a
Windows zip, a setup exe and a macOS zip uploaded to the public release.
"""
import re
import unittest
from pathlib import Path

from test_windows_builds_do_not_run_under_bash import jobs

WORKFLOWS = Path(__file__).resolve().parents[2] / ".github" / "workflows"
RELEASE = (WORKFLOWS / "release.yml").read_text()
DESKTOP = (WORKFLOWS / "desktop-clients.yml").read_text()

VERIFY_JOB = "verify-client-ci"
REQUIRED = re.compile(r'required_checks:\s*"([^"]*)"')
NEEDS_VERIFY = re.compile(r"^    needs:\s*\[[^\]]*\b" + VERIFY_JOB + r"\b[^\]]*\]", re.M)


def required_checks(text: str, job: str) -> str | None:
    match = REQUIRED.search(jobs(text).get(job, ""))
    return match.group(1) if match else None


def ungated_asset_jobs(text: str) -> list[str]:
    """Jobs that attach to a release without needing the verify job."""
    return [
        name
        for name, body in jobs(text).items()
        if "gh release upload" in body and not NEEDS_VERIFY.search(body)
    ]


class DesktopClientsWaitsForTheReleaseGateTest(unittest.TestCase):
    def test_it_asks_for_exactly_the_checks_release_asks_for(self):
        ours = required_checks(DESKTOP, VERIFY_JOB)
        self.assertIsNotNone(ours, "desktop-clients.yml has no verify-client-ci call")
        self.assertEqual(ours, required_checks(RELEASE, VERIFY_JOB))

    def test_it_verifies_the_tag_it_builds(self):
        body = jobs(DESKTOP)[VERIFY_JOB]
        self.assertIn("uses: ./.github/workflows/verify-release-checks.yml", body)
        self.assertRegex(body, r"ref:\s*\$\{\{\s*inputs\.tag \|\| github\.ref_name\s*\}\}")

    def test_the_verify_call_can_read_checks(self):
        self.assertRegex(jobs(DESKTOP)[VERIFY_JOB], r"checks:\s*read")

    def test_every_job_that_attaches_to_the_release_needs_it(self):
        self.assertEqual(ungated_asset_jobs(DESKTOP), [])
        self.assertIn("windows-client", jobs(DESKTOP))
        self.assertIn("macos-client", jobs(DESKTOP))

    def test_the_gate_sees_an_ungated_upload(self):
        broken = (
            "jobs:\n  windows-client:\n    needs: [other]\n    steps:\n"
            "      - run: gh release upload t a.zip\n"
            "  macos-client:\n    steps:\n      - run: gh release upload t b.zip\n"
        )
        self.assertEqual(ungated_asset_jobs(broken), ["windows-client", "macos-client"])
        fixed = broken.replace("[other]", "[verify-client-ci]").replace(
            "  macos-client:\n", "  macos-client:\n    needs: [verify-client-ci, x]\n"
        )
        self.assertEqual(ungated_asset_jobs(fixed), [])


if __name__ == "__main__":
    unittest.main()
