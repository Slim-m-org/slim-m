# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""main-builds must not decide the web image from the push's own diff alone.

`cancel-in-progress: true` can cancel the run that was building the web image
and the next push, touching no client file, skips it; the web image then stays
stale until the next client push. The `web` output asks what is undeployed.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TEXT = (ROOT / ".github" / "workflows" / "main-builds.yml").read_text()


def job_block(name: str) -> str:
    found = re.search(rf"^  {name}:\n((?:    .*\n|\s*\n)+)", TEXT, re.M)
    return found.group(1) if found else ""


class MainBuildsWebImageDecidesFromWhatIsDeployedTest(unittest.TestCase):
    def test_web_image_is_gated_on_its_own_output(self):
        self.assertIn("needs.changes.outputs.web == 'true'", job_block("web-image"))

    def test_the_web_output_ors_in_the_undeployed_check(self):
        output = re.search(r"^      web: (.+)$", job_block("changes"), re.M)
        self.assertIsNotNone(output, "changes has no web output")
        self.assertIn("steps.filter.outputs.client == 'true'", output.group(1))
        self.assertIn("steps.undeployed.outputs.web == 'true'", output.group(1))

    def test_the_undeployed_step_runs_the_web_script(self):
        self.assertIn("scripts/web-image-needed.sh", job_block("changes"))

    def test_client_jobs_still_decide_from_the_push_diff(self):
        output = re.search(r"^      client: (.+)$", job_block("changes"), re.M)
        self.assertNotIn("undeployed", output.group(1))


if __name__ == "__main__":
    unittest.main()
