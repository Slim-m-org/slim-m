# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The loadtest token cache: how it is written and how obtain() uses it."""
import json
import os
import stat
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import load_accounts as LA  # noqa: E402

URL = "http://loadtest.invalid"


class FakeApi:
    def __init__(self, token):
        self.token = token


def rows(n):
    return [{"username": f"u{i}", "display_name": f"U{i}",
             "token": f"t{i}", "refresh": f"r{i}"} for i in range(n)]


class CacheDirTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.path = LA._cache_path(self.dir, URL)
        old = os.umask(0o022)
        self.addCleanup(os.umask, old)


class SaveCacheTest(CacheDirTest):
    def test_the_file_is_never_readable_by_others(self):
        modes = []
        real = json.dump

        def spy(obj, handle, **kw):
            modes.extend(stat.S_IMODE(p.stat().st_mode)
                         for p in self.dir.iterdir())
            return real(obj, handle, **kw)

        with mock.patch.object(LA.json, "dump", spy):
            LA._save_cache(self.path, rows(2))
        self.assertTrue(modes)
        self.assertEqual({m & 0o077 for m in modes}, {0})
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o600)

    def test_an_interrupted_save_keeps_the_previous_cache(self):
        LA._save_cache(self.path, rows(5))

        def dump_then_die(obj, handle, **kw):
            handle.write("[")
            raise KeyboardInterrupt

        with mock.patch.object(LA.json, "dump", dump_then_die):
            with self.assertRaises(KeyboardInterrupt):
                LA._save_cache(self.path, rows(2))
        self.assertEqual(len(LA._load_cache(self.path)), 5)
        self.assertEqual([p.name for p in self.dir.iterdir()],
                         [self.path.name])


class ObtainTest(CacheDirTest):
    def seed(self, n):
        LA._save_cache(self.path, rows(n))

    def revive(self, base_url, entry):
        return FakeApi(entry["token"]), entry["refresh"]

    def test_a_smaller_count_keeps_the_other_entries(self):
        self.seed(10)
        with mock.patch.object(LA, "_revive", self.revive):
            accounts, cached = LA.obtain(URL, 3, "pw", None, self.dir)
        self.assertTrue(cached)
        self.assertEqual(len(accounts), 3)
        self.assertEqual(len(LA._load_cache(self.path)), 10)

    def test_a_cache_hit_enrols_nobody(self):
        self.seed(3)
        with mock.patch.object(LA, "_revive", self.revive), \
                mock.patch.object(LA, "_enrol_all") as enrol:
            accounts, cached = LA.obtain(URL, 3, "pw", None, self.dir)
        self.assertTrue(cached)
        enrol.assert_not_called()
        self.assertEqual([a["username"] for a in accounts], ["u0", "u1", "u2"])

    def test_a_refreshed_token_pair_is_written_back(self):
        self.seed(2)

        def revive(base_url, entry):
            return FakeApi("fresh-" + entry["username"]), "rot-" + entry["username"]

        with mock.patch.object(LA, "_revive", revive):
            LA.obtain(URL, 2, "pw", None, self.dir)
        saved = LA._load_cache(self.path)
        self.assertEqual([r["token"] for r in saved], ["fresh-u0", "fresh-u1"])
        self.assertEqual([r["refresh"] for r in saved], ["rot-u0", "rot-u1"])

    def test_an_account_that_cannot_revive_logs_in_for_itself_alone(self):
        self.seed(3)

        def revive(base_url, entry):
            if entry["username"] == "u1":
                return None, None
            return FakeApi(entry["token"]), entry["refresh"]

        login = {"username": "u1", "display_name": "U1",
                 "api": FakeApi("login-token"), "refresh": "login-refresh",
                 "reused": True}
        with mock.patch.object(LA, "_revive", revive), \
                mock.patch.object(LA, "_login", return_value=login) as lg, \
                mock.patch.object(LA, "_enrol_all") as enrol:
            accounts, cached = LA.obtain(URL, 3, "pw", None, self.dir)
        self.assertTrue(cached)
        lg.assert_called_once()
        enrol.assert_not_called()
        self.assertEqual(accounts[1]["api"].token, "login-token")

    def test_a_failed_login_falls_back_to_enrolling_everyone(self):
        self.seed(2)
        err = urllib.error.HTTPError(URL, 401, "no", {}, None)
        enrolled = [{"username": f"n{i}", "display_name": f"N{i}",
                     "api": FakeApi(f"nt{i}"), "refresh": f"nr{i}",
                     "reused": False} for i in range(2)]
        with mock.patch.object(LA, "_revive", lambda b, e: (None, None)), \
                mock.patch.object(LA, "_login", side_effect=err), \
                mock.patch.object(LA, "_enrol_all", return_value=enrolled):
            accounts, cached = LA.obtain(URL, 2, "pw", None, self.dir)
        self.assertFalse(cached)
        self.assertEqual([r["username"] for r in LA._load_cache(self.path)],
                         ["n0", "n1"])

    def test_a_cache_smaller_than_the_count_enrols(self):
        self.seed(1)
        enrolled = [{"username": f"n{i}", "display_name": f"N{i}",
                     "api": FakeApi(f"nt{i}"), "refresh": None,
                     "reused": False} for i in range(2)]
        with mock.patch.object(LA, "_enrol_all", return_value=enrolled):
            _, cached = LA.obtain(URL, 2, "pw", None, self.dir)
        self.assertFalse(cached)
        self.assertEqual(len(LA._load_cache(self.path)), 2)


if __name__ == "__main__":
    unittest.main()
