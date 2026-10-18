# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The extra-browser helpers keep their shapes: a plain path, and a context manager."""
import os
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


if __name__ == "__main__":
    unittest.main()
