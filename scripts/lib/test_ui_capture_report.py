# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The ui capture report decides whether a capture run is complete, so each
way a job can fail has to show up in the manifest, the failure list and the
table row the same way."""
import contextlib
import io
import json
import re
import shutil
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import ui_capture_html  # noqa: E402
import ui_capture_report  # noqa: E402


def _event(**fields):
    return json.dumps(fields)


def _passing_log(*names):
    lines = []
    for index, name in enumerate(names, start=1):
        lines.append(_event(type="testStart", test={"id": index, "name": name}))
        lines.append(_event(type="testDone", testID=index, result="success", hidden=False))
    return "\n".join(lines) + "\n"


def _failing_log(name, error):
    return "\n".join([
        _event(type="testStart", test={"id": 1, "name": name}),
        _event(type="error", testID=1, error=error),
        _event(type="testDone", testID=1, result="failure", hidden=False),
    ]) + "\n"


class ReportCase(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="ui-capture-report-test-"))
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.work = self.root / "_work"
        self.work.mkdir()

    def add_job(self, job_id, *, category="screens", exit_code=0, images=1, log=None):
        meta = {"id": job_id, "category": category, "test_file": f"test/{job_id}.dart",
                "exit_code": exit_code, "images": images}
        (self.work / f"{job_id}.meta").write_text(json.dumps(meta))
        if log is not None:
            (self.work / f"{job_id}.json").write_text(log, encoding="utf-8")

    def manifest(self):
        return ui_capture_report.build_manifest(self.root, self.work)


class JobOutcomeTest(ReportCase):
    def test_a_clean_job_is_ok_with_no_failures(self):
        self.add_job("a", log=_passing_log("renders"))
        manifest = self.manifest()
        self.assertTrue(manifest["ok"])
        self.assertEqual(ui_capture_html.collect_failures(manifest), [])
        self.assertIn("Every capture rendered.", ui_capture_html.render_html(manifest))

    def test_a_failed_test_fails_the_run(self):
        self.add_job("a", exit_code=1, log=_failing_log("renders", "boom"))
        manifest = self.manifest()
        self.assertFalse(manifest["ok"])
        failures = ui_capture_html.collect_failures(manifest)
        self.assertEqual([(f["job"], f["name"], f["error"]) for f in failures],
                         [("a", "renders", "boom")])

    def test_a_nonzero_exit_with_no_failed_test_is_a_harness_failure(self):
        self.add_job("a", exit_code=137, log=_passing_log("renders"))
        manifest = self.manifest()
        self.assertFalse(manifest["ok"])
        failures = ui_capture_html.collect_failures(manifest)
        self.assertEqual(failures[0]["error"], "flutter test exited 137")

    def test_passing_tests_that_wrote_no_image_are_a_silent_gap(self):
        self.add_job("a", images=0, log=_passing_log("renders"))
        manifest = self.manifest()
        self.assertFalse(manifest["ok"])
        self.assertIn("wrote zero images",
                      ui_capture_html.collect_failures(manifest)[0]["error"])

    def test_a_job_with_no_log_and_no_tests_is_not_a_silent_gap(self):
        self.add_job("a", images=0, log=None)
        self.assertTrue(self.manifest()["ok"])

    def test_the_banner_and_every_row_agree_with_the_failure_list(self):
        self.add_job("good", log=_passing_log("renders"))
        self.add_job("failed", exit_code=1, log=_failing_log("renders", "boom"))
        self.add_job("gap", images=0, log=_passing_log("renders"))
        self.add_job("crashed", exit_code=137, log=_passing_log("renders"))
        manifest = self.manifest()
        page = ui_capture_html.render_html(manifest)
        by_job = {job: cls for cls, job in re.findall(r"<tr class=(ok|bad)><td>(\w+)</td>", page)}
        self.assertEqual(by_job, {"good": "ok", "failed": "bad", "gap": "bad", "crashed": "bad"})
        self.assertEqual(manifest["ok"], not ui_capture_html.collect_failures(manifest))
        self.assertIn("Something did not render", page)


class DamagedInputTest(ReportCase):
    def test_a_log_cut_off_mid_line_fails_that_job_and_still_reports(self):
        log = _passing_log("renders") + '{"type":"testDo'
        self.add_job("a", exit_code=137, log=log)
        manifest = self.manifest()
        self.assertFalse(manifest["ok"])
        failures = ui_capture_html.collect_failures(manifest)
        self.assertTrue(any("unreadable" in (f["name"] or "") for f in failures), failures)
        self.assertIn("Something did not render", ui_capture_html.render_html(manifest))

    def test_a_log_cut_off_inside_a_multibyte_character_still_reports(self):
        raw = (_passing_log("renders") + '{"error":"').encode() + "é".encode()[:1]
        self.add_job("a", log="")
        (self.work / "a.json").write_bytes(raw)
        self.assertFalse(self.manifest()["ok"])

    def test_an_unreadable_meta_file_fails_the_run(self):
        (self.work / "broken.meta").write_text('{"id":"brok')
        manifest = self.manifest()
        self.assertFalse(manifest["ok"])
        self.assertTrue(ui_capture_html.collect_failures(manifest))

    def test_main_writes_the_sheet_even_when_a_log_is_truncated(self):
        self.add_job("a", exit_code=137, log='{"type":"testDo')
        argv = ["ui_capture_report.py", "--out", str(self.root), "--work", str(self.work)]
        with unittest.mock.patch.object(sys, "argv", argv), \
             contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(ui_capture_report.main(), 1)
        self.assertIn("Something did not render", (self.root / "index.html").read_text())


if __name__ == "__main__":
    unittest.main()
