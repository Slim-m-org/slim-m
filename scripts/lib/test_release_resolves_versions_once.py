# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The release version and tag are resolved once, in the release-please job.

Six copies of the release-please-output-or-ref-name block used to live in the
publish jobs, each emitting a slightly different set, and the android copy
emitted only the tag and left `--build-name=` empty. Publish jobs now read
`needs.release-please.outputs.*`.
"""
import re
import unittest
from pathlib import Path

from test_windows_builds_do_not_run_under_bash import jobs

WORKFLOWS = Path(__file__).resolve().parents[2] / ".github" / "workflows"
RELEASE = (WORKFLOWS / "release.yml").read_text()
RESOLVE = re.compile(r"GITHUB_REF_NAME#(?:server|client)-v")


def code_only(text: str) -> str:
    return "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))


class ReleaseResolvesVersionsOnceTest(unittest.TestCase):
    def test_only_the_release_please_job_strips_a_tag_prefix(self):
        for name, body in jobs(RELEASE).items():
            with self.subTest(job=name):
                found = RESOLVE.findall(code_only(body))
                self.assertEqual(len(found), 2 if name == "release-please" else 0)

    def test_the_reusable_publish_workflows_do_not_strip_a_tag_prefix(self):
        for name in ("server-binaries.yml", "web-image.yml"):
            with self.subTest(workflow=name):
                self.assertEqual(RESOLVE.findall(code_only((WORKFLOWS / name).read_text())), [])

    def test_release_please_outputs_fall_back_to_the_ref_name(self):
        outputs = jobs(RELEASE)["release-please"]
        for key in ("server_version", "server_tag", "client_version", "client_tag"):
            with self.subTest(output=key):
                self.assertRegex(outputs, rf"{key}: \$\{{\{{ steps\.rp-(?:server|client)\.outputs\[[^\]]+\] \|\| steps\.resolved\.outputs\.{key} \}}\}}")

    def test_no_publish_job_keeps_a_ver_step(self):
        for name, body in jobs(RELEASE).items():
            with self.subTest(job=name):
                self.assertNotIn("steps.ver.outputs", body)


if __name__ == "__main__":
    unittest.main()
