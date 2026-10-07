# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Unit coverage for which commit the last published server image came from.

The cases here are the real 2026-09-10 shapes: a cancelled run that built
nothing, a string of client-only runs that skipped the server side, and the
release-published image that none of them account for. Getting this wrong in
the quiet direction is what the whole change exists to stop, so "cannot tell"
must never be reported as "already published".
"""
import io
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))

import server_image_base as m  # noqa: E402


def run(sha, server=None, other=None):
    jobs = []
    if server is not None:
        jobs.append({"name": "server-image", "conclusion": server})
    for name, conclusion in (other or []):
        jobs.append({"name": name, "conclusion": conclusion})
    return {"headSha": sha, "jobs": jobs}


class BaseShaTest(unittest.TestCase):
    def test_the_newest_successful_publish_wins(self):
        runs = [
            run("ccc", server="skipped"),
            run("bbb", server="success"),
            run("aaa", server="success"),
        ]
        self.assertEqual(m.base_sha(runs), "bbb")

    def test_a_cancelled_publish_does_not_count(self):
        """The 2026-09-10 shape: cancelled, then skipped all the way down."""
        runs = [
            run("fff", server="skipped"),
            run("eee", server="skipped"),
            run("ddd", server="cancelled"),
            run("ccc", server="success"),
        ]
        self.assertEqual(m.base_sha(runs), "ccc")

    def test_a_failed_publish_does_not_count(self):
        runs = [run("bbb", server="failure"), run("aaa", server="success")]
        self.assertEqual(m.base_sha(runs), "aaa")

    def test_no_publish_in_range_is_cannot_tell(self):
        """None means fall back to the push diff, never 'nothing to build'."""
        runs = [run("bbb", server="skipped"), run("aaa", server="skipped")]
        self.assertIsNone(m.base_sha(runs))

    def test_a_run_with_no_server_job_at_all_is_skipped_over(self):
        runs = [
            run("bbb", other=[("linux-client", "success")]),
            run("aaa", server="success"),
        ]
        self.assertEqual(m.base_sha(runs), "aaa")

    def test_the_current_commit_does_not_count_as_its_own_base(self):
        """A rerun would otherwise diff a commit against itself and build nothing."""
        runs = [run("bbb", server="success"), run("aaa", server="success")]
        self.assertEqual(m.base_sha(runs, skip_sha="bbb"), "aaa")

    def test_an_empty_history_is_cannot_tell(self):
        self.assertIsNone(m.base_sha([]))


WEB = "web-image / merge"


class WebImageBaseTest(unittest.TestCase):
    """The web image has the same cancelled-then-skipped hole as the server image."""

    def test_the_web_merge_job_is_what_counts(self):
        runs = [
            run("ccc", other=[("web-image", "skipped")]),
            run("bbb", other=[("web-image / build (amd64, ubuntu-24.04)", "success"), (WEB, "cancelled")]),
            run("aaa", other=[(WEB, "success")]),
        ]
        self.assertEqual(m.base_sha(runs, job=WEB), "aaa")

    def test_a_server_publish_is_not_a_web_publish(self):
        runs = [run("bbb", server="success"), run("aaa", other=[(WEB, "success")])]
        self.assertEqual(m.base_sha(runs, job=WEB), "aaa")
        self.assertEqual(m.base_sha(runs), "bbb")

    def test_main_reads_the_job_name_from_the_second_argument(self):
        body = '[{"headSha":"abc","jobs":[{"name":"web-image / merge","conclusion":"success"}]}]'
        out = io.StringIO()
        with patch.object(sys, "stdin", io.StringIO(body)), patch.object(sys, "stdout", out):
            m.main(["server_image_base.py", "", WEB])
        self.assertEqual(out.getvalue().strip(), "abc")


class MainTest(unittest.TestCase):
    def _main(self, stdin_text, argv=("server_image_base.py",)):
        out = io.StringIO()
        with patch.object(sys, "stdin", io.StringIO(stdin_text)), patch.object(
            sys, "stdout", out
        ):
            code = m.main(list(argv))
        return code, out.getvalue().strip()

    def test_it_prints_the_sha(self):
        body = '[{"headSha":"abc","jobs":[{"name":"server-image","conclusion":"success"}]}]'
        self.assertEqual(self._main(body), (0, "abc"))

    def test_malformed_json_is_empty_rather_than_a_crash(self):
        """A GitHub hiccup must degrade to the old behaviour, not fail the run."""
        self.assertEqual(self._main("not json at all"), (0, ""))

    def test_an_unexpected_shape_is_empty_rather_than_a_crash(self):
        self.assertEqual(self._main('{"message":"Not Found"}'), (0, ""))


if __name__ == "__main__":
    unittest.main()
