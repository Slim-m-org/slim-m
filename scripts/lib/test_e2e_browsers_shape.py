# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The extra-browser helpers keep their shapes: a plain path, and a context manager."""
import contextlib
import io
import os
import subprocess
import sys
import unittest
from unittest import mock

import e2e_browsers


class BrowsersShapeTest(unittest.TestCase):
    def test_work_dir_is_a_path_from_the_environment(self):
        with mock.patch.dict(os.environ, {"E2E_WORK": "/somewhere/e2e"}):
            self.assertEqual(e2e_browsers.work_dir(), "/somewhere/e2e")

    def test_work_dir_falls_back_to_a_path(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertIsInstance(e2e_browsers.work_dir(), str)

    def test_browser_is_a_context_manager_and_starts_nothing_until_entered(self):
        handle = e2e_browsers.browser("carol", "voice.wav")
        self.assertTrue(hasattr(handle, "__enter__"))
        self.assertTrue(hasattr(handle, "__exit__"))


class StaleBrowsersTest(unittest.TestCase):
    BASE = 61000

    def spawn(self, port, joined=False):
        """A stand-in for a Chrome: any process carrying the debugging flag, as its own argument or inside one string."""
        flag = f"--remote-debugging-port={port}"
        args = [f"--headless=new {flag} --no-first-run"] if joined else [flag]
        proc = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)", *args])
        self.addCleanup(proc.wait)
        self.addCleanup(proc.kill)
        return proc

    def test_every_port_a_run_can_use_is_covered(self):
        ports = e2e_browsers.debug_ports(self.BASE)
        self.assertEqual(len(ports), len(set(ports)))
        for offset in (1, 2, *e2e_browsers.EXTRA_OFFSETS.values()):
            self.assertIn(self.BASE + offset, ports)

    def test_a_browser_left_on_any_of_them_is_found_and_stopped(self):
        left = [self.spawn(port) for port in e2e_browsers.debug_ports(self.BASE)]
        stopped = e2e_browsers.stop_stale_browsers(self.BASE)
        self.assertEqual(sorted(stopped), sorted(proc.pid for proc in left))
        for proc in left:
            proc.wait(timeout=10)

    def test_a_browser_that_rewrote_its_command_line_into_one_string_is_found(self):
        joined = self.spawn(self.BASE + 17, joined=True)
        self.assertEqual(e2e_browsers.stop_stale_browsers(self.BASE), [joined.pid])
        joined.wait(timeout=10)

    def test_another_run_s_browser_and_a_longer_port_number_are_left_alone(self):
        other_run = self.spawn(self.BASE + 1000 + 1)
        longer = self.spawn(f"{self.BASE + 1}0", joined=True)
        self.assertEqual(e2e_browsers.stop_stale_browsers(self.BASE), [])
        self.assertIsNone(other_run.poll())
        self.assertIsNone(longer.poll())

    def test_the_command_line_helper_reports_what_it_stopped(self):
        self.spawn(self.BASE + 2)
        out = io.StringIO()
        with mock.patch.dict(os.environ, {"E2E_CDP_BASE": str(self.BASE)}), \
                contextlib.redirect_stdout(out):
            e2e_browsers.main(["e2e_browsers.py", "stop-stale"])
        self.assertIn("stopped 1 browser(s)", out.getvalue())


if __name__ == "__main__":
    unittest.main()
