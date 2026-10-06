# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""ui-capture.sh keeps a hand-written JOBS list, so a snapshot harness added
to the app package is silently left off the contact sheet unless this fails."""
import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

ROOT = Path(__file__).resolve().parents[2]
APP_TEST_DIR = ROOT / "client" / "packages" / "app" / "test"
SNAPSHOT_FILE = re.compile(r"^ui_(overlay_)?snapshot_.+_test\.dart$")


def _jobs():
    text = (ROOT / "scripts" / "ui-capture.sh").read_text(encoding="utf-8")
    block = re.search(r"^JOBS=\(\n(.*?)^\)", text, re.S | re.M).group(1)
    jobs = []
    for line in re.findall(r'^\s*"([^"]+)"\s*$', block, re.M):
        job_id, category, cwd, _env, _src, test_file = line.split("|")
        jobs.append({"id": job_id, "category": category, "cwd": cwd, "test_file": test_file})
    return jobs


def _app_jobs():
    return [j for j in _jobs() if j["cwd"] == "client/packages/app"]


class UiCaptureJobsTest(unittest.TestCase):
    def test_every_snapshot_harness_in_the_app_package_has_a_job(self):
        on_disk = {
            f"test/{p.name}" for p in APP_TEST_DIR.iterdir() if SNAPSHOT_FILE.match(p.name)
        }
        listed = {j["test_file"] for j in _app_jobs()}
        self.assertEqual(sorted(on_disk - listed), [])

    def test_every_job_names_a_test_file_that_exists(self):
        for job in _jobs():
            path = ROOT / job["cwd"] / job["test_file"]
            self.assertTrue(path.is_file(), f"{job['id']}: {path} is missing")

    def test_a_harness_lands_in_the_category_its_name_prefix_says(self):
        for job in _app_jobs():
            name = Path(job["test_file"]).name
            if not SNAPSHOT_FILE.match(name):
                continue
            expected = "overlays" if name.startswith("ui_overlay_") else "screens"
            self.assertEqual(job["category"], expected, job["id"])

    def test_job_ids_are_unique(self):
        ids = [j["id"] for j in _jobs()]
        self.assertEqual(len(ids), len(set(ids)))


if __name__ == "__main__":
    unittest.main()
