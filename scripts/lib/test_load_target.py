# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The load runner's target guard, driven without any network or server."""
import io
import sys
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import load_target  # noqa: E402
import seed_guard  # noqa: E402


class CheckTest(unittest.TestCase):
    def test_loopback_targets_pass_and_lose_the_trailing_slash(self):
        for url in ("http://127.0.0.1:8195/", "http://localhost:8195",
                    "http://127.1.2.3:80", "http://[::1]:8195"):
            self.assertEqual(load_target.check(url), url.rstrip("/"))

    def test_production_is_refused_by_name_and_by_lan_address(self):
        for url in ("https://slim.npc-server.top", "http://10.0.0.100:8095",
                    "https://npc-server.top"):
            with self.assertRaises(seed_guard.GuardError, msg=url):
                load_target.check(url)

    def test_any_other_host_is_refused(self):
        for url in ("http://192.168.1.5:8195", "http://example.com",
                    "http://0.0.0.0:8195", "http://localhost.evil.test"):
            with self.assertRaises(seed_guard.GuardError, msg=url):
                load_target.check(url)

    def test_a_missing_or_malformed_url_is_refused(self):
        for url in ("", None, "ftp://127.0.0.1", "127.0.0.1:8195"):
            with self.assertRaises(seed_guard.GuardError, msg=repr(url)):
                load_target.check(url)


class MainTest(unittest.TestCase):
    def run_main(self, argv):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = load_target.main(["load_target.py", *argv])
        return code, out.getvalue(), err.getvalue()

    def test_exit_codes_and_output(self):
        self.assertEqual(self.run_main(["http://127.0.0.1:8195"])[:2],
                         (0, "http://127.0.0.1:8195\n"))
        code, out, err = self.run_main(["https://slim.npc-server.top"])
        self.assertEqual((code, out), (1, ""))
        self.assertIn("refusing", err)
        self.assertEqual(self.run_main([])[0], 2)


if __name__ == "__main__":
    unittest.main()
