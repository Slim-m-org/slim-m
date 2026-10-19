# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""e2e_client's import-time behaviour and how it reads a script's result."""
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import e2e_client  # noqa: E402


class ImportHasNoSideEffectsTest(unittest.TestCase):
    def test_importing_the_harness_creates_no_temp_directories(self):
        env = {k: v for k, v in os.environ.items()
               if k not in ("E2E_SHOTS", "E2E_FIXTURES")}
        with tempfile.TemporaryDirectory() as tmp:
            env["TMPDIR"] = tmp
            subprocess.run(
                [sys.executable, "-I", "-c",
                 f"import sys; sys.path.insert(0, {str(HERE)!r}); "
                 "import e2e_client, e2e_run"],
                env=env, check=True)
            self.assertEqual(os.listdir(tmp), [])


class ScriptedClient(e2e_client.Client):
    def __init__(self, reply):
        super().__init__("t", 0)
        self.reply = reply
        self.taps = []

    def send(self, method, params=None):
        return self.reply

    def tap(self, x, y):
        self.taps.append((x, y))


class EvTest(unittest.TestCase):
    THREW = {"id": 1, "result": {"exceptionDetails": {
        "text": "Uncaught",
        "exception": {"description": "ReferenceError: nope is not defined"}}}}

    def test_ev_returns_the_value(self):
        c = ScriptedClient({"id": 1, "result": {"result": {"value": 7}}})
        self.assertEqual(c.ev("1+6"), 7)

    def test_ev_raises_when_the_script_threw(self):
        c = ScriptedClient(self.THREW)
        with self.assertRaisesRegex(AssertionError, "ReferenceError"):
            c.ev("nope")

    def test_click_does_not_fall_back_to_a_tap_when_the_script_threw(self):
        c = ScriptedClient(self.THREW)
        c.wait_for = lambda label, **kw: {"x": 1, "y": 2}
        with self.assertRaises(AssertionError):
            c.click("Send", settle=0)
        self.assertEqual(c.taps, [])


if __name__ == "__main__":
    unittest.main()


class BootClient(e2e_client.Client):
    def __init__(self, boots_after_reload):
        super().__init__("t", 0)
        self.boots_after_reload = boots_after_reload
        self.reloaded = False
        self.shots = []

    def send(self, method, params=None):
        if method == "Page.reload":
            self.reloaded = True
        return {}

    def ev(self, expr):
        return self.reloaded and self.boots_after_reload

    def shot(self, tag):
        self.shots.append(tag)


class WaitForBootTest(unittest.TestCase):
    def test_a_page_that_never_booted_is_reloaded_once_and_then_boots(self):
        client = BootClient(boots_after_reload=True)
        client._wait_for_boot(timeout=4)
        self.assertTrue(client.reloaded)
        self.assertEqual(client.shots, [])

    def test_a_page_that_still_does_not_boot_leaves_a_shot_and_fails(self):
        client = BootClient(boots_after_reload=False)
        with self.assertRaisesRegex(AssertionError, "never booted"):
            client._wait_for_boot(timeout=2)
        self.assertEqual(client.shots, ["app-never-booted"])
